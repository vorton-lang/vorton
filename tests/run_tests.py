#!/usr/bin/env python3
"""
Ring-lang Python test runner (B-151 P2).

Replaces the retired Node-based test harnesses with a single C-native Python
runner that depends only on the stdlib.

Usage:
    python tests/run_tests.py                        # all suites
    python tests/run_tests.py --suite e2e            # single-file e2e
    python tests/run_tests.py --suite golden         # golden snapshots
    python tests/run_tests.py --suite self-compile   # tracked dist-c fixed point
    python tests/run_tests.py --suite structural     # generated-C structural gates
    python tests/run_tests.py --suite parity         # static evidence matrix
    python tests/run_tests.py --suite ownership-vertical  # #268/#269 real fixtures
    python tests/run_tests.py --filter substr        # only cases matching substr
    python tests/run_tests.py --update-golden        # regenerate .expected
"""

from __future__ import annotations

import argparse
import atexit
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple

from ownership_vertical_runner import (
    ExactPanicObservation,
    RunnerContext,
    normal_diagnostic_contract_failure,
    run_ownership_vertical,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPO = Path(__file__).resolve().parent.parent
CASES_DIR = REPO / "tests" / "cases"
GOLDEN_CASES_DIR = CASES_DIR / "golden"
NATIVE_ONLY_DIR = CASES_DIR / "native_only"
MODULES_DIR = CASES_DIR / "modules"
RUNTIME_CPP = REPO / "ring_runtime.cpp"
RUNTIME_O = REPO / "ring_runtime.o"
DIST_C_DIR = REPO / "compiler" / "dist-c"
DIST_C_MAIN = DIST_C_DIR / "main.c"
THINLTO_CACHE = Path(tempfile.gettempdir()) / "ring-lang-thinlto-cache"
COMPILER_ARTIFACT_CACHE = (
    Path(tempfile.gettempdir()) / "ring-lang-compiler-anchor-cache-v3"
)
COMPILER_CACHE_ENV = "RING_TEST_COMPILER_CACHE"
IDENTITY_CANDIDATE_ENV = "RING_IDENTITY_CANDIDATE_EXE"
IDENTITY_EVIDENCE_ROOT_ENV = "RING_IDENTITY_EVIDENCE_ROOT"
COMPILER_CACHE_SCHEMA = "ring.test-runner-compiler-anchor-cache.v3"
COMPILER_CACHE_VERSION = 3
COMPILER_CACHE_POISON_SCHEMA = "ring.test-runner-compiler-anchor-poison.v1"
COMPILER_CACHE_POISON_VERSION = 1
COMPILER_CACHE_MAX_ENTRIES = 16
COMPILER_CACHE_MAX_BYTES = 4 * 1024 * 1024 * 1024
COMPILER_CACHE_STALE_SECONDS = 24 * 60 * 60
COMPILER_CACHE_MAX_CONFLICTS = 32
PARITY_MATRIX = REPO / "tests" / "parity_matrix.json"
STRUCTURAL_DIR = CASES_DIR / "structural"
CODEGEN_C_SOURCE = REPO / "compiler" / "codegen_c.ring"
NATIVE_REAL_PROGRAM = REPO / "tests" / "native" / "real_program.ring"
NATIVE_REAL_PROGRAM_EXPECTED = NATIVE_REAL_PROGRAM.with_suffix(".expected")

sys.path.insert(0, str(REPO / ".agents" / "scripts"))
from one_shot_gate import (  # noqa: E402
    Limits as OneShotLimits,
    OneShotSpec,
    ResultSchemaError as OneShotResultSchemaError,
    audit_attempt as audit_one_shot_attempt,
    create_archive as create_one_shot_archive,
    run_one_shot,
)

# CLI-observable contracts that used to live in the retired in-process Node
# harness.  Keeping them explicit prevents companion discovery from silently
# dropping parser-recovery and rich-diagnostic coverage.
RECOVERY_CASES = (
    "error_recovery_match.ring",
    "error_recovery_handle.ring",
    "error_recovery_if.ring",
)

ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")

# Generated-C evidence owned by the structural suite.  This map is also the
# parity contract: every fixture below must exist, every structural .ring file
# must appear exactly once, and the matching matrix row must list the same set.
C_LINE_BUILD_CASES = (
    (
        "single-file",
        "tests/cases/structural/c_line_single.ring",
        ("tests/cases/structural/c_line_single.ring",),
    ),
    (
        "minimal-project",
        "tests/cases/structural/c_line_project/main.ring",
        (
            "tests/cases/structural/c_line_project/main.ring",
            "tests/cases/structural/c_line_project/probe.ring",
        ),
    ),
)
EXTERN_RC_FIXTURE = "tests/cases/structural/extern_handle_rc.ring"
STRUCTURAL_ORACLE_FIXTURES = {
    "backend.c_line_directives": tuple(
        fixture
        for _, _, fixtures in C_LINE_BUILD_CASES
        for fixture in fixtures
    ),
    "backend.extern_handle_rc_structural": (EXTERN_RC_FIXTURE,),
}

# Subdirectories within tests/cases/ that also contain negative test cases.
EXTRA_NEG_DIRS = ["negative", "errors"]

TIMEOUT_COMPILE = 60   # seconds, for ring.exe build / check
TIMEOUT_LINK = 60      # seconds, for clang link
TIMEOUT_COMPILER_LINK = 300  # cold ThinLTO link on slower CI hosts
TIMEOUT_RUN = 30       # seconds, per test program execution
TIMEOUT_SELFCOMPILE = 1200  # seconds; 900 was exceeded after B-170, and clean
                            # self-compiles take about 18 minutes

PHASE_TIMING_SCHEMA = "ring.test-runner-phase.v1"
PHASE_TIMING_VERSION = 1
PHASE_TIMING_FIELDS = frozenset({
    "schema", "version", "sequence", "suite", "case", "stage",
    "duration_ns", "executed", "complete", "outcome", "exit_code",
    "command_category",
})

# Every retained gap carries an actionable reason instead of a bare skip name.
SHARED_POSITIVE_GAPS = {}

# Positive cases whose `ring check` itself fails today.  Unlike shared
# execution gaps, these are frontend blockers, so every lane that would compile
# the case (golden/e2e/native/module) must skip it with the same actionable reason.
CHECK_BLOCKED_POSITIVE_GAPS = {}

CHECK_ONLY_GAPS = {}

# Windows-specific clang link flags.
# /MANIFEST:EMBED + /MANIFESTUAC:asInvoker prevents Windows Installer Detection
# from requiring elevation for test exes whose names contain "update"/"install"/etc.
CLANG_LINK_FLAGS = [
    # Keep every test link on LLD.  On hosted Windows runners, clang's default
    # MSVC linker/manifest path can exhaust the runner's USER-handle allowance
    # and return 1158 before the first executable is produced.  The compiler
    # link already used LLD; using the same path here is both faster and stable.
    "-fuse-ld=lld",
    "-lmsvcrt",
    "-Wl,/STACK:536870912",
    "-Wl,/MANIFEST:EMBED",
    "-Wl,/MANIFESTUAC:level='asInvoker'",
]

# The self-hosted compiler is CPU-bound. O3 + ThinLTO is about 20% faster on a
# compiler/main.ring check than the former O2 build. The content-addressed LLD
# cache makes repeat links effectively free while bounding cache growth.
COMPILER_COMPILE_FLAGS = ["-O3", "-flto=thin"]
COMPILER_LINK_FLAGS = [
    "-flto=thin",
    f"-Wl,/lldltocache:{THINLTO_CACHE}",
    (
        "-Wl,/lldltocachepolicy:cache_size_bytes=1073741824:"
        "cache_size_files=4096:prune_after=168h"
    ),
]

# ---------------------------------------------------------------------------
# Result tracking
# ---------------------------------------------------------------------------

class TestResult:
    PASS = "PASS"
    FAIL = "FAIL"
    SKIP = "SKIP"

    def __init__(self, status: str, suite: str, name: str, detail: str = ""):
        self.status = status
        self.suite = suite
        self.name = name
        self.detail = detail

    def __str__(self) -> str:
        tag = f"[{self.status}]"
        label = f"{self.suite}: {self.name}"
        if self.detail:
            return f"{tag} {label} -- {self.detail}"
        return f"{tag} {label}"


class ResultCollector:
    def __init__(self) -> None:
        self.results: List[TestResult] = []

    def add(self, r: TestResult) -> None:
        self.results.append(r)
        print(str(r), flush=True)

    def summary(self) -> dict[str, dict[str, int]]:
        """Return {suite: {pass: N, fail: N, skip: N}}."""
        out: dict[str, dict[str, int]] = {}
        for r in self.results:
            if r.suite not in out:
                out[r.suite] = {"pass": 0, "fail": 0, "skip": 0}
            key = r.status.lower()
            out[r.suite][key] = out[r.suite].get(key, 0) + 1
        return out

    @property
    def failures(self) -> int:
        return sum(1 for r in self.results if r.status == TestResult.FAIL)


# ---------------------------------------------------------------------------
# Opt-in phase timing
# ---------------------------------------------------------------------------

@dataclass
class _SuitePhaseState:
    name: str
    started_ns: int
    child_duration_ns: int = 0


class PhaseTimingTrace:
    """Monotonic JSONL trace for the explicitly enabled timing mode."""

    def __init__(self, output_path: str) -> None:
        self._stream = open(output_path, "w", encoding="utf-8", newline="\n")
        self._sequence = 0
        self._runner_started_ns = time.perf_counter_ns()
        self._runner_accounted_ns = 0
        self._suite_state: Optional[_SuitePhaseState] = None
        self._finished = False

    @property
    def current_suite(self) -> Optional[str]:
        if self._suite_state is None:
            return None
        return self._suite_state.name

    def close(self) -> None:
        self._stream.close()

    def _emit(
        self,
        *,
        suite: Optional[str],
        case: Optional[str],
        stage: str,
        duration_ns: int,
        executed: bool,
        complete: bool,
        outcome: str,
        exit_code: Optional[int],
        command_category: Optional[str],
    ) -> None:
        self._sequence += 1
        record = {
            "schema": PHASE_TIMING_SCHEMA,
            "version": PHASE_TIMING_VERSION,
            "sequence": self._sequence,
            "suite": suite,
            "case": case,
            "stage": stage,
            "duration_ns": max(0, duration_ns),
            "executed": executed,
            "complete": complete,
            "outcome": outcome,
            "exit_code": exit_code,
            "command_category": command_category,
        }
        self._stream.write(json.dumps(
            record, sort_keys=True, separators=(",", ":"), allow_nan=False,
        ))
        self._stream.write("\n")
        self._stream.flush()

    def _account_child(self, suite: Optional[str], duration_ns: int) -> None:
        if self._suite_state is not None and suite == self._suite_state.name:
            self._suite_state.child_duration_ns += duration_ns
        else:
            self._runner_accounted_ns += duration_ns

    def record_stage(
        self,
        *,
        suite: Optional[str],
        case: Optional[str],
        stage: str,
        duration_ns: int,
        executed: bool,
        complete: bool,
        outcome: str,
        exit_code: Optional[int] = None,
        command_category: Optional[str] = None,
    ) -> None:
        """Record a non-overlapping stage measured by runner orchestration."""
        self._account_child(suite, duration_ns)
        self._emit(
            suite=suite, case=case, stage=stage, duration_ns=duration_ns,
            executed=executed, complete=complete, outcome=outcome,
            exit_code=exit_code, command_category=command_category,
        )

    def run_subprocess(
        self,
        stage: str,
        command: Sequence[str],
        *,
        suite: Optional[str],
        case: Optional[str],
        command_category: str,
        run_kwargs: Dict[str, Any],
    ) -> subprocess.CompletedProcess:
        started_ns = time.perf_counter_ns()
        try:
            result = subprocess.run(command, **run_kwargs)
        except subprocess.TimeoutExpired:
            duration_ns = time.perf_counter_ns() - started_ns
            self._account_child(suite, duration_ns)
            self._emit(
                suite=suite, case=case, stage=stage, duration_ns=duration_ns,
                executed=True, complete=False, outcome="timeout",
                exit_code=None, command_category=command_category,
            )
            raise
        except subprocess.CalledProcessError as exc:
            duration_ns = time.perf_counter_ns() - started_ns
            self._account_child(suite, duration_ns)
            self._emit(
                suite=suite, case=case, stage=stage, duration_ns=duration_ns,
                executed=True, complete=True, outcome="nonzero",
                exit_code=exc.returncode, command_category=command_category,
            )
            raise
        except OSError:
            duration_ns = time.perf_counter_ns() - started_ns
            self._account_child(suite, duration_ns)
            self._emit(
                suite=suite, case=case, stage=stage, duration_ns=duration_ns,
                executed=False, complete=False, outcome="spawn-error",
                exit_code=None, command_category=command_category,
            )
            raise
        except BaseException:
            duration_ns = time.perf_counter_ns() - started_ns
            self._account_child(suite, duration_ns)
            self._emit(
                suite=suite, case=case, stage=stage, duration_ns=duration_ns,
                executed=True, complete=False, outcome="exception",
                exit_code=None, command_category=command_category,
            )
            raise

        duration_ns = time.perf_counter_ns() - started_ns
        self._account_child(suite, duration_ns)
        exit_code = result.returncode
        self._emit(
            suite=suite, case=case, stage=stage, duration_ns=duration_ns,
            executed=True, complete=True,
            outcome="success" if exit_code == 0 else "nonzero",
            exit_code=exit_code, command_category=command_category,
        )
        return result

    def run_suite(self, suite: str, callback: Callable[[], None]) -> None:
        if self._suite_state is not None:
            raise RuntimeError("phase-timed suites must not be nested")
        state = _SuitePhaseState(suite, time.perf_counter_ns())
        self._suite_state = state
        complete = False
        outcome = "exception"
        exit_code: Optional[int] = None
        try:
            callback()
            complete = True
            outcome = "completed"
        except subprocess.TimeoutExpired:
            outcome = "timeout"
            raise
        except subprocess.CalledProcessError as exc:
            outcome = "nonzero"
            exit_code = exc.returncode
            raise
        finally:
            duration_ns = time.perf_counter_ns() - state.started_ns
            self._suite_state = None
            residual_ns = max(0, duration_ns - state.child_duration_ns)
            self._emit(
                suite=suite, case=None, stage="orchestration_residual",
                duration_ns=residual_ns, executed=True, complete=complete,
                outcome=outcome, exit_code=exit_code, command_category=None,
            )
            self._emit(
                suite=suite, case=None, stage="suite_total",
                duration_ns=duration_ns, executed=True, complete=complete,
                outcome=outcome, exit_code=exit_code, command_category=None,
            )
            self._runner_accounted_ns += duration_ns

    def finish(self, *, complete: bool, outcome: str,
               exit_code: Optional[int]) -> None:
        if self._finished:
            return
        self._finished = True
        duration_ns = time.perf_counter_ns() - self._runner_started_ns
        residual_ns = max(0, duration_ns - self._runner_accounted_ns)
        self._emit(
            suite=None, case="runner", stage="orchestration_residual",
            duration_ns=residual_ns, executed=True, complete=complete,
            outcome=outcome, exit_code=exit_code, command_category=None,
        )
        self._emit(
            suite=None, case="runner", stage="runner_total",
            duration_ns=duration_ns, executed=True, complete=complete,
            outcome=outcome, exit_code=exit_code, command_category=None,
        )


_PHASE_TRACER: Optional[PhaseTimingTrace] = None


def _phase_timing_path(value: str) -> str:
    if not os.path.isabs(value):
        raise argparse.ArgumentTypeError(
            "--phase-timing requires an absolute output path")
    return value


def _phase_command_category(stage: str) -> str:
    if stage in {"ring_check", "ring_build"}:
        return "ring"
    if stage == "run_exe":
        return "generated-program"
    return "clang"


def _run_subprocess(
    stage: str,
    command: Sequence[str],
    *,
    phase_suite: Optional[str] = None,
    phase_case: Optional[str] = None,
    **run_kwargs: Any,
) -> subprocess.CompletedProcess:
    """Run one child, adding timing only when the trace is explicitly enabled."""
    tracer = _PHASE_TRACER
    if tracer is None:
        return subprocess.run(command, **run_kwargs)
    suite = phase_suite if phase_suite is not None else tracer.current_suite
    case = phase_case if phase_case is not None else (
        "runner" if suite is None else None
    )
    return tracer.run_subprocess(
        stage, command, suite=suite, case=case,
        command_category=_phase_command_category(stage),
        run_kwargs=run_kwargs,
    )


def _run_timed_suite(suite: str, callback: Callable[[], None]) -> None:
    tracer = _PHASE_TRACER
    if tracer is None:
        callback()
        return
    tracer.run_suite(suite, callback)


# ---------------------------------------------------------------------------
# Tool discovery
# ---------------------------------------------------------------------------

def find_clang() -> Optional[str]:
    """Return the clang executable path, or None."""
    return shutil.which("clang")


@dataclass(frozen=True)
class _CompilerBuildPlan:
    anchor_source: Path
    runtime_source: Path
    clang: str
    runtime_compiler: str
    runtime_frontend_flags: Tuple[str, ...]
    linker: str
    exe_name: str
    compile_flags: Tuple[str, ...]
    test_link_flags: Tuple[str, ...]
    compiler_link_flags: Tuple[str, ...]
    controlled: bool
    cache_supported: bool
    target: Optional[str]
    driver_flags: Tuple[str, ...]
    linker_pin_flags: Tuple[str, ...]
    environment: Tuple[Tuple[str, str], ...]


class CompilerPreparationError(RuntimeError):
    """The tracked compiler could not be prepared without weakening trust."""


@dataclass(frozen=True)
class _CachedAnchor:
    path: Path
    sha256: str
    size: int
    mode: int


_CONTROLLED_ENV_NAMES = (
    "SystemRoot",
    "WINDIR",
    "TEMP",
    "TMP",
    "INCLUDE",
    "LIB",
    "LIBPATH",
    "CPATH",
    "C_INCLUDE_PATH",
    "CPLUS_INCLUDE_PATH",
    "OBJC_INCLUDE_PATH",
    "LIBRARY_PATH",
    "COMPILER_PATH",
    "GCC_EXEC_PREFIX",
    "SDKROOT",
    "MACOSX_DEPLOYMENT_TARGET",
    "VCINSTALLDIR",
    "VCToolsInstallDir",
    "VCToolsVersion",
    "VSINSTALLDIR",
    "VisualStudioVersion",
    "WindowsSdkDir",
    "WindowsSDKVersion",
    "UniversalCRTSdkDir",
    "UCRTVersion",
)
_CACHE_THREAD_LOCKS: Dict[str, threading.RLock] = {}
_CACHE_THREAD_LOCKS_GUARD = threading.Lock()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _stable_file_identity(path: Path, *, include_mode: bool = False) -> Dict[str, Any]:
    resolved = path.resolve(strict=True)
    before = resolved.stat()
    if not stat.S_ISREG(before.st_mode):
        raise CompilerPreparationError(f"cache input is not a regular file: {resolved}")
    digest = _sha256_file(resolved)
    after = resolved.stat()
    if (
        before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
    ):
        raise CompilerPreparationError(f"cache input changed while hashing: {resolved}")
    record: Dict[str, Any] = {
        "path": os.path.normcase(str(resolved)),
        "size": after.st_size,
        "sha256": digest,
    }
    if include_mode:
        record["mode"] = stat.S_IMODE(after.st_mode)
    return record


def _resolved_executable(executable: str) -> Optional[str]:
    candidate = shutil.which(executable)
    if candidate is None:
        path = Path(executable)
        if not path.is_file():
            return None
        candidate = str(path)
    try:
        return str(Path(candidate).resolve(strict=True))
    except OSError:
        return None


def _find_lld_linker(clang: str) -> Optional[str]:
    if sys.platform == "win32":
        names = ("lld-link.exe", "lld-link")
    elif sys.platform == "darwin":
        names = ("ld64.lld", "ld.lld", "lld")
    else:
        names = ("ld.lld", "lld")

    try:
        clang_dir = Path(clang).resolve(strict=True).parent
    except OSError:
        clang_dir = Path(clang).parent
    for name in names:
        sibling = clang_dir / name
        if sibling.is_file():
            return str(sibling.resolve())
    for name in names:
        resolved = _resolved_executable(name)
        if resolved is not None:
            return resolved
    return None


def _environment_value(name: str) -> Optional[str]:
    folded = name.casefold()
    for key, value in os.environ.items():
        if key.casefold() == folded:
            return value
    return None


def _controlled_environment(*tools: str) -> Tuple[Tuple[str, str], ...]:
    environment: Dict[str, str] = {}
    for name in _CONTROLLED_ENV_NAMES:
        value = _environment_value(name)
        if value is not None:
            environment[name] = value

    path_dirs: List[str] = []
    for tool in tools:
        directory = str(Path(tool).resolve(strict=True).parent)
        if os.path.normcase(directory) not in {
            os.path.normcase(existing) for existing in path_dirs
        }:
            path_dirs.append(directory)
    system_root = environment.get("SystemRoot") or environment.get("WINDIR")
    if system_root:
        system32 = str(Path(system_root) / "System32")
        if os.path.normcase(system32) not in {
            os.path.normcase(existing) for existing in path_dirs
        }:
            path_dirs.append(system32)
    environment["PATH"] = os.pathsep.join(path_dirs)
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    environment["SOURCE_DATE_EPOCH"] = "0"
    return tuple(sorted(environment.items(), key=lambda item: item[0].casefold()))


def _plan_environment(plan: _CompilerBuildPlan) -> Optional[Dict[str, str]]:
    if not plan.controlled:
        return None
    return dict(plan.environment)


def _probe_controlled_target(
    compiler: str,
    environment: Tuple[Tuple[str, str], ...],
) -> Optional[str]:
    try:
        result = subprocess.run(
            [compiler, "--no-default-config", "-dumpmachine"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
            cwd=str(REPO),
            env=dict(environment),
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        return None
    target = result.stdout.strip()
    if not target or re.fullmatch(r"[A-Za-z0-9_.+-]+", target) is None:
        return None
    return target


def _system_include_probe_source(path: Path) -> str:
    """Return preprocessor directives while preserving conditional includes."""

    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return ""
    directives: List[str] = []
    continuing = False
    for line in source.splitlines():
        stripped = line.lstrip()
        if continuing or stripped.startswith("#"):
            directives.append(line)
            continuing = line.rstrip().endswith("\\")
        else:
            # Preserve line boundaries so a directive cannot be joined to an
            # adjacent token, but omit ordinary declarations and definitions.
            directives.append("")
    probe = "\n".join(directives) + ("\n" if source.endswith(("\n", "\r")) else "")
    if re.search(r"(?m)^\s*#\s*include\s*<", probe) is None:
        return ""
    return probe


def _probe_controlled_system_headers(
    compiler: str,
    driver_flags: Tuple[str, ...],
    environment: Tuple[Tuple[str, str], ...],
    source_path: Path,
    language: str,
    standard: str,
    extra_flags: Tuple[str, ...] = (),
) -> bool:
    """Prove the candidate controlled driver can resolve actual system headers."""

    probe_source = _system_include_probe_source(source_path)
    if not probe_source:
        return False
    command = [
        compiler,
        *driver_flags,
        *extra_flags,
        f"-std={standard}",
        *COMPILER_COMPILE_FLAGS,
        "-iquote",
        str(source_path.parent.resolve()),
        "-E",
        "-x",
        language,
        "-",
    ]
    try:
        result = subprocess.run(
            command,
            input=probe_source,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=TIMEOUT_COMPILE,
            cwd=str(REPO),
            env=dict(environment),
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    return result.returncode == 0


def _compiler_build_plan() -> Optional[_CompilerBuildPlan]:
    if not DIST_C_MAIN.is_file() or not RUNTIME_CPP.is_file():
        return None
    clang_discovered = find_clang()
    if clang_discovered is None:
        return None
    clang = _resolved_executable(clang_discovered)
    if clang is None:
        return None

    cpp_discovered = shutil.which("clang++")
    cpp_compiler = (
        _resolved_executable(cpp_discovered)
        if cpp_discovered is not None else None
    )
    if cpp_compiler is None:
        runtime_compiler = clang
        runtime_frontend_flags = ("-x", "c++")
    else:
        runtime_compiler = cpp_compiler
        runtime_frontend_flags = ()

    linker = _find_lld_linker(clang)
    controlled = False
    cache_supported = False
    target: Optional[str] = None
    driver_flags: Tuple[str, ...] = ()
    linker_pin_flags: Tuple[str, ...] = ()
    environment: Tuple[Tuple[str, str], ...] = ()
    if sys.platform == "win32" and linker is not None:
        environment = _controlled_environment(
            clang, runtime_compiler, linker,
        )
        clang_target = _probe_controlled_target(clang, environment)
        runtime_target = _probe_controlled_target(runtime_compiler, environment)
        if clang_target is not None and clang_target == runtime_target:
            candidate_driver_flags = (
                "--no-default-config",
                f"--target={clang_target}",
            )
            c_headers = _probe_controlled_system_headers(
                clang,
                candidate_driver_flags,
                environment,
                DIST_C_MAIN,
                "c",
                "c11",
            )
            cxx_headers = _probe_controlled_system_headers(
                runtime_compiler,
                candidate_driver_flags,
                environment,
                RUNTIME_CPP,
                "c++",
                "c++17",
                runtime_frontend_flags + ("-D_CRT_SECURE_NO_WARNINGS",),
            )
            if c_headers and cxx_headers:
                controlled = True
                cache_supported = True
                target = clang_target
                driver_flags = candidate_driver_flags
                linker_pin_flags = (f"-B{Path(linker).resolve().parent}",)
    return _CompilerBuildPlan(
        anchor_source=DIST_C_MAIN,
        runtime_source=RUNTIME_CPP,
        clang=clang,
        runtime_compiler=runtime_compiler,
        runtime_frontend_flags=runtime_frontend_flags,
        # The ordinary path preserves clang's own -fuse-ld=lld discovery.
        # Only the controlled Windows cache path requires an explicit linker.
        linker=linker or "",
        exe_name="ring.exe" if sys.platform == "win32" else "ring",
        compile_flags=tuple(COMPILER_COMPILE_FLAGS),
        test_link_flags=tuple(CLANG_LINK_FLAGS),
        compiler_link_flags=tuple(COMPILER_LINK_FLAGS),
        controlled=controlled,
        cache_supported=cache_supported,
        target=target,
        driver_flags=driver_flags,
        linker_pin_flags=linker_pin_flags,
        environment=environment,
    )


def _tool_identity(executable: str) -> Dict[str, Any]:
    return _stable_file_identity(Path(executable))


def _anchor_driver_arguments(
    plan: _CompilerBuildPlan,
    anchor_source: Path,
) -> List[str]:
    arguments = [
        *plan.driver_flags,
        "-std=c11",
        *plan.compile_flags,
    ]
    if plan.controlled:
        tracked_anchor_dir = plan.anchor_source.parent.resolve()
        arguments.extend([
            "-iquote", str(tracked_anchor_dir),
            f"-ffile-prefix-map={anchor_source.parent}={tracked_anchor_dir}",
        ])
    return arguments


def _compiler_commands(
    plan: _CompilerBuildPlan,
    build_dir: Path,
    anchor_source: Path,
) -> Tuple[List[str], List[str], List[str], Path, Path]:
    object_path = build_dir / "main.o"
    runtime_object_path = build_dir / "runtime.o"
    exe_path = build_dir / plan.exe_name
    anchor_cmd = [
        plan.clang,
        *_anchor_driver_arguments(plan, anchor_source),
        "-c", str(anchor_source), "-o", str(object_path),
    ]
    runtime_cmd = [
        plan.runtime_compiler,
        *plan.driver_flags,
        *plan.runtime_frontend_flags,
        "-std=c++17", *plan.compile_flags,
        "-D_CRT_SECURE_NO_WARNINGS", "-c", str(plan.runtime_source),
        "-o", str(runtime_object_path),
    ]
    link_cmd = [
        plan.clang,
        *plan.driver_flags,
        *plan.linker_pin_flags,
        str(object_path), str(runtime_object_path), "-o", str(exe_path),
        *plan.test_link_flags, *plan.compiler_link_flags,
    ]
    return anchor_cmd, runtime_cmd, link_cmd, exe_path, object_path


def _canonical_compiler_recipes(plan: _CompilerBuildPlan) -> Dict[str, List[str]]:
    tracked_anchor_dir = str(plan.anchor_source.parent.resolve())
    anchor_prefix_map = (
        f"-ffile-prefix-map=$anchor_snapshot_dir={tracked_anchor_dir}"
    )
    anchor_arguments: List[str] = [
        "$clang", *plan.driver_flags, "-std=c11", *plan.compile_flags,
    ]
    if plan.controlled:
        anchor_arguments.extend([
            "-iquote", tracked_anchor_dir,
            anchor_prefix_map,
        ])
    return {
        "anchor_dependency_scan": [
            *anchor_arguments,
            "-E", "-dM", "-MD",
            "-MT", "ring-cache-probe", "-MF", "$depfile",
            "$tracked_anchor_snapshot",
        ],
        "anchor_compile": [
            *anchor_arguments,
            "-c", "$tracked_anchor_snapshot", "-o", "$anchor_object",
        ],
        "runtime_compile": [
            "$runtime_compiler", *plan.driver_flags,
            *plan.runtime_frontend_flags,
            "-std=c++17", *plan.compile_flags,
            "-D_CRT_SECURE_NO_WARNINGS", "-c", "$runtime",
            "-o", "$runtime_object",
        ],
        "link": [
            "$clang", *plan.driver_flags, *plan.linker_pin_flags,
            "$anchor_object", "$runtime_object", "-o", "$compiler_executable",
            *plan.test_link_flags, *plan.compiler_link_flags,
        ],
    }


def _parse_make_dependencies(text: str) -> List[str]:
    flattened = re.sub(r"\\\r?\n", " ", text)
    prefix = "ring-cache-probe:"
    if not flattened.startswith(prefix):
        raise CompilerPreparationError(
            "compiler dependency output has an unexpected target"
        )
    body = flattened[len(prefix):]
    tokens: List[str] = []
    current: List[str] = []
    index = 0
    while index < len(body):
        char = body[index]
        if char.isspace():
            if current:
                tokens.append("".join(current).replace("$$", "$"))
                current = []
            index += 1
            continue
        if char == "\\" and index + 1 < len(body):
            following = body[index + 1]
            if following.isspace() or following == "#":
                current.append(following)
                index += 2
                continue
        current.append(char)
        index += 1
    if current:
        tokens.append("".join(current).replace("$$", "$"))
    if not tokens:
        raise CompilerPreparationError("compiler dependency closure is empty")
    return tokens


def _scan_anchor_dependencies(
    plan: _CompilerBuildPlan,
    anchor_snapshot: Path,
    probe_dir: Path,
) -> Tuple[Tuple[Dict[str, Any], ...], str]:
    descriptor, depfile_name = tempfile.mkstemp(
        prefix="anchor-", suffix=".d", dir=str(probe_dir),
    )
    os.close(descriptor)
    depfile = Path(depfile_name)
    try:
        command = [
            plan.clang,
            *_anchor_driver_arguments(plan, anchor_snapshot),
            "-E", "-dM", "-MD",
            "-MT", "ring-cache-probe", "-MF", str(depfile),
            str(anchor_snapshot),
        ]
        result = _run_subprocess(
            "compiler_anchor_dependency_scan", command,
            check=True,
            capture_output=True,
            timeout=TIMEOUT_COMPILE,
            cwd=str(REPO),
            env=_plan_environment(plan),
        )
        try:
            dependency_text = depfile.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            raise CompilerPreparationError(
                f"cannot read compiler dependency closure: {exc}"
            ) from exc
    finally:
        depfile.unlink(missing_ok=True)

    snapshot_resolved = anchor_snapshot.resolve(strict=True)
    dependencies: Dict[str, Dict[str, Any]] = {}
    for token in _parse_make_dependencies(dependency_text):
        candidate = Path(token)
        if not candidate.is_absolute():
            candidate = REPO / candidate
        try:
            resolved = candidate.resolve(strict=True)
        except OSError as exc:
            raise CompilerPreparationError(
                f"compiler dependency cannot be resolved: {token!r}"
            ) from exc
        if resolved == snapshot_resolved:
            continue
        record = _stable_file_identity(resolved)
        dependencies[record["path"]] = record
    closure = tuple(dependencies[path] for path in sorted(dependencies))
    preprocessor_state = hashlib.sha256(result.stdout).hexdigest()
    return closure, preprocessor_state


def _compiler_cache_inputs(
    plan: _CompilerBuildPlan,
    anchor_snapshot: Path,
    probe_dir: Path,
) -> Dict[str, Any]:
    if not plan.cache_supported or not plan.controlled:
        raise CompilerPreparationError(
            "compiler anchor cache requires a controlled Windows recipe"
        )
    dependencies, preprocessor_state = _scan_anchor_dependencies(
        plan, anchor_snapshot, probe_dir,
    )
    anchor_identity = _stable_file_identity(anchor_snapshot)
    anchor_identity["path"] = "$tracked_c_anchor"
    return {
        "schema": COMPILER_CACHE_SCHEMA,
        "version": COMPILER_CACHE_VERSION,
        "anchor": anchor_identity,
        "dependency_closure": list(dependencies),
        "preprocessor_state_sha256": preprocessor_state,
        "recipes": _canonical_compiler_recipes(plan),
        "tools": {
            "clang": _tool_identity(plan.clang),
            "runtime_compiler": _tool_identity(plan.runtime_compiler),
            "linker": _tool_identity(plan.linker),
        },
        "target": plan.target,
        "working_directory": os.path.normcase(str(REPO.resolve())),
        "platform": {
            "sys_platform": sys.platform,
            "os_name": os.name,
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
        },
        "environment": dict(plan.environment),
    }


def _compiler_cache_key(inputs: Dict[str, Any]) -> str:
    encoded = json.dumps(
        inputs, sort_keys=True, separators=(",", ":"), allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _compiler_cache_enabled() -> bool:
    value = os.environ.get(COMPILER_CACHE_ENV, "1")
    return value.strip().casefold() not in {"0", "false", "no", "off"}


def _stage_anchor_snapshot(
    plan: _CompilerBuildPlan,
    staging_dir: Path,
) -> Path:
    source_dir = staging_dir / "inputs"
    source_dir.mkdir()
    staged_anchor = source_dir / "main.c"
    before = _stable_file_identity(plan.anchor_source)
    shutil.copy2(plan.anchor_source, staged_anchor)
    staged = _stable_file_identity(staged_anchor)
    after = _stable_file_identity(plan.anchor_source)
    for field in ("size", "sha256"):
        if before[field] != staged[field] or before[field] != after[field]:
            raise CompilerPreparationError(
                "tracked C anchor changed while taking the cache snapshot"
            )
    return staged_anchor


def _compile_anchor(
    plan: _CompilerBuildPlan,
    build_dir: Path,
    anchor_source: Path,
) -> Path:
    anchor_cmd, _, _, _, object_path = _compiler_commands(
        plan, build_dir, anchor_source,
    )
    THINLTO_CACHE.mkdir(parents=True, exist_ok=True)
    _run_subprocess(
        "compiler_anchor_compile", anchor_cmd,
        check=True, capture_output=True, timeout=TIMEOUT_SELFCOMPILE,
        cwd=str(REPO), env=_plan_environment(plan),
    )
    if not object_path.is_file():
        raise CompilerPreparationError(
            "anchor compilation succeeded without producing main.o"
        )
    return object_path


def _compile_runtime_and_link(
    plan: _CompilerBuildPlan,
    build_dir: Path,
    anchor_source: Path,
) -> Path:
    _, runtime_cmd, link_cmd, exe_path, _ = _compiler_commands(
        plan, build_dir, anchor_source,
    )
    _run_subprocess(
        "compiler_runtime_compile", runtime_cmd,
        check=True, capture_output=True, timeout=TIMEOUT_COMPILE,
        cwd=str(REPO), env=_plan_environment(plan),
    )
    # A cache hit skips _compile_anchor(), which normally creates this shared
    # LLD ThinLTO cache directory before the fresh link.
    THINLTO_CACHE.mkdir(parents=True, exist_ok=True)
    _run_subprocess(
        "compiler_link", link_cmd,
        check=True, capture_output=True, timeout=TIMEOUT_COMPILER_LINK,
        cwd=str(REPO), env=_plan_environment(plan),
    )
    if not exe_path.is_file():
        raise CompilerPreparationError(
            "compiler link succeeded without producing the executable"
        )
    return exe_path


def _cache_paths(cache_root: Path, key: str) -> Tuple[Path, Path]:
    return cache_root / "receipts" / f"{key}.json", cache_root / "artifacts"


def _cache_poison_path(cache_root: Path, key: str) -> Path:
    return cache_root / "poisoned" / f"{key}.json"


def _cache_thread_lock(path: Path) -> threading.RLock:
    key = os.path.normcase(str(path.resolve()))
    with _CACHE_THREAD_LOCKS_GUARD:
        lock = _CACHE_THREAD_LOCKS.get(key)
        if lock is None:
            lock = threading.RLock()
            _CACHE_THREAD_LOCKS[key] = lock
        return lock


class _CacheFileLock:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._stream: Any = None
        self._thread_lock = _cache_thread_lock(path)

    def __enter__(self) -> "_CacheFileLock":
        self._thread_lock.acquire()
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self._stream = self.path.open("a+b")
            self._stream.seek(0, os.SEEK_END)
            if self._stream.tell() == 0:
                self._stream.write(b"\0")
                self._stream.flush()
            self._stream.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self._stream.fileno(), msvcrt.LK_LOCK, 1)
            else:
                import fcntl
                fcntl.flock(self._stream.fileno(), fcntl.LOCK_EX)
            return self
        except BaseException:
            if self._stream is not None:
                self._stream.close()
                self._stream = None
            self._thread_lock.release()
            raise

    def __exit__(self, exc_type, exc, traceback) -> None:
        try:
            if os.name == "nt":
                import msvcrt
                self._stream.seek(0)
                msvcrt.locking(self._stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(self._stream.fileno(), fcntl.LOCK_UN)
        finally:
            self._stream.close()
            self._stream = None
            self._thread_lock.release()


def _cache_global_lock(cache_root: Path) -> _CacheFileLock:
    return _CacheFileLock(cache_root / "locks" / "global.lock")


def _cache_key_lock(cache_root: Path, key: str) -> _CacheFileLock:
    # A fixed stripe preserves same-key exclusion without allowing an
    # unbounded lock-file/thread-lock registry as cache keys turn over.
    return _CacheFileLock(cache_root / "locks" / "keys" / f"{key[:2]}.lock")


def _artifact_mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def _validated_cached_anchor(
    cache_root: Path,
    key: str,
    inputs: Dict[str, Any],
) -> Optional[_CachedAnchor]:
    receipt_path, artifacts_dir = _cache_paths(cache_root, key)
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        if set(receipt) != {
            "schema", "version", "key", "inputs", "artifact",
            "artifact_sha256", "artifact_size", "artifact_mode",
        }:
            return None
        if (
            receipt["schema"] != COMPILER_CACHE_SCHEMA
            or receipt["version"] != COMPILER_CACHE_VERSION
            or receipt["key"] != key
            or receipt["inputs"] != inputs
            or _compiler_cache_key(receipt["inputs"]) != key
        ):
            return None
        artifact_hash = receipt["artifact_sha256"]
        artifact_size = receipt["artifact_size"]
        artifact_mode = receipt["artifact_mode"]
        if (
            not isinstance(artifact_hash, str)
            or re.fullmatch(r"[0-9a-f]{64}", artifact_hash) is None
            or not isinstance(artifact_size, int)
            or isinstance(artifact_size, bool)
            or artifact_size < 0
            or not isinstance(artifact_mode, int)
            or isinstance(artifact_mode, bool)
            or artifact_mode < 0
        ):
            return None
        artifact_name = f"{artifact_hash}.o"
        if receipt["artifact"] != artifact_name:
            return None
        artifact_path = artifacts_dir / artifact_name
        if artifact_path.stat().st_size != artifact_size:
            return None
        if _sha256_file(artifact_path) != artifact_hash:
            return None
        if _artifact_mode(artifact_path) != artifact_mode:
            return None
        return _CachedAnchor(
            artifact_path, artifact_hash, artifact_size, artifact_mode,
        )
    except (OSError, ValueError, TypeError, KeyError):
        return None


def _write_json_temp(parent: Path, prefix: str, value: Dict[str, Any]) -> Path:
    parent.mkdir(parents=True, exist_ok=True)
    descriptor, temp_name = tempfile.mkstemp(
        prefix=prefix, suffix=".tmp", dir=str(parent),
    )
    temp_path = Path(temp_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(
                value, stream, sort_keys=True,
                separators=(",", ":"), allow_nan=False,
            )
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        return temp_path
    except BaseException:
        temp_path.unlink(missing_ok=True)
        raise


def _hardlink_once(source: Path, destination: Path) -> bool:
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(source, destination)
        return True
    except FileExistsError:
        return False
    except OSError as exc:
        raise CompilerPreparationError(
            f"compiler cache requires atomic hard-link publication: {exc}"
        ) from exc


def _create_json_once(path: Path, value: Dict[str, Any]) -> bool:
    temp_path = _write_json_temp(path.parent, f".{path.stem}-", value)
    try:
        return _hardlink_once(temp_path, path)
    finally:
        temp_path.unlink(missing_ok=True)


def _touch_cache_access(cache_root: Path, key: str) -> None:
    access = cache_root / "access" / key
    access.parent.mkdir(parents=True, exist_ok=True)
    access.touch(exist_ok=True)


def _record_cache_conflict_locked(
    cache_root: Path,
    key: str,
    winner: _CachedAnchor,
    candidate: _CachedAnchor,
) -> Path:
    evidence_dir = cache_root / "conflicts" / key
    evidence_path = evidence_dir / (
        f"{time.time_ns()}-{os.getpid()}-{threading.get_ident()}.json"
    )
    evidence = {
        "schema": COMPILER_CACHE_SCHEMA,
        "version": COMPILER_CACHE_VERSION,
        "key": key,
        "winner": {
            "sha256": winner.sha256,
            "size": winner.size,
            "mode": winner.mode,
        },
        "candidate": {
            "sha256": candidate.sha256,
            "size": candidate.size,
            "mode": candidate.mode,
        },
    }
    if not _create_json_once(evidence_path, evidence):
        raise CompilerPreparationError(
            f"compiler cache conflict evidence already exists: {evidence_path}"
        )
    _prune_cache_conflicts_locked(cache_root)
    return evidence_path


def _poison_cache_key_locked(
    cache_root: Path,
    key: str,
    winner: _CachedAnchor,
    candidate: _CachedAnchor,
) -> Path:
    poison_path = _cache_poison_path(cache_root, key)
    receipt_path, _ = _cache_paths(cache_root, key)
    poison_path.parent.mkdir(parents=True, exist_ok=True)
    marker = {
        "schema": COMPILER_CACHE_POISON_SCHEMA,
        "version": COMPILER_CACHE_POISON_VERSION,
        "key": key,
        "reason": "same_key_divergent_anchor_objects",
        "winner": {
            "sha256": winner.sha256,
            "size": winner.size,
            "mode": winner.mode,
        },
        "candidate": {
            "sha256": candidate.sha256,
            "size": candidate.size,
            "mode": candidate.mode,
        },
    }
    try:
        # The existing receipt is already durable and immutable.  Rename it as
        # the poison commit point before writing best-effort conflict details.
        # Thus a later diagnostic fsync/hard-link failure cannot turn a proven
        # same-key divergence back into a normal cache miss.
        os.replace(receipt_path, poison_path)
    except OSError as exc:
        try:
            if _create_json_once(poison_path, marker) or poison_path.is_file():
                return poison_path
        except BaseException:
            # Last independent persistence path: destroy the valid receipt in
            # place and replace it with a poison record that lookup and cleanup
            # both understand.  Opening with "w" truncates before any later
            # write/fsync error, so it cannot remain a valid cache hit.
            try:
                with receipt_path.open("w", encoding="utf-8", newline="\n") as stream:
                    json.dump(
                        marker, stream, sort_keys=True,
                        separators=(",", ":"), allow_nan=False,
                    )
                    stream.write("\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                return receipt_path
            except BaseException as fallback_exc:
                raise CompilerPreparationError(
                    "cannot durably poison divergent compiler cache key: "
                    f"rename={exc}; fallback={fallback_exc}"
                ) from fallback_exc
    return poison_path


def _is_cache_poison_record(value: Any, key: str) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {
            "schema", "version", "key", "reason",
            "winner", "candidate",
        }
        and value.get("schema") == COMPILER_CACHE_POISON_SCHEMA
        and value.get("version") == COMPILER_CACHE_POISON_VERSION
        and value.get("key") == key
        and value.get("reason") == "same_key_divergent_anchor_objects"
        and _is_cache_poison_identity(value.get("winner"))
        and _is_cache_poison_identity(value.get("candidate"))
        and value["winner"] != value["candidate"]
    )


def _is_cache_poison_identity(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"sha256", "size", "mode"}
        and isinstance(value.get("sha256"), str)
        and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) is not None
        and isinstance(value.get("size"), int)
        and not isinstance(value["size"], bool)
        and value["size"] >= 0
        and isinstance(value.get("mode"), int)
        and not isinstance(value["mode"], bool)
        and value["mode"] >= 0
    )


def _reject_poisoned_cache_key_locked(cache_root: Path, key: str) -> None:
    poison_path = _cache_poison_path(cache_root, key)
    receipt_path, _ = _cache_paths(cache_root, key)
    poisoned_in_place = False
    if receipt_path.is_file():
        try:
            poisoned_in_place = _is_cache_poison_record(
                json.loads(receipt_path.read_text(encoding="utf-8")), key,
            )
        except (OSError, ValueError, TypeError):
            pass
    if poison_path.exists() or poisoned_in_place:
        evidence_path = poison_path if poison_path.exists() else receipt_path
        raise CompilerPreparationError(
            "compiler anchor cache key is poisoned by a prior divergent build; "
            f"disable {COMPILER_CACHE_ENV} or purge the cache entry to recover: "
            f"{evidence_path}"
        )


def _same_cached_anchor(left: _CachedAnchor, right: _CachedAnchor) -> bool:
    return (
        left.sha256 == right.sha256
        and left.size == right.size
        and left.mode == right.mode
    )


def _remove_path(path: Path) -> None:
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


def _cleanup_compiler_cache_locked(
    cache_root: Path,
    *,
    now: Optional[float] = None,
    protected_keys: Tuple[str, ...] = (),
) -> None:
    current_time = time.time() if now is None else now
    stale_before = current_time - COMPILER_CACHE_STALE_SECONDS
    for path in cache_root.glob(".staging-*"):
        if path.stat().st_mtime < stale_before:
            _remove_path(path)
    for directory_name in ("receipts", "artifacts", "poisoned"):
        directory = cache_root / directory_name
        if directory.is_dir():
            for path in directory.glob(".*.tmp"):
                if path.stat().st_mtime < stale_before:
                    _remove_path(path)
    conflict_root = cache_root / "conflicts"
    if conflict_root.is_dir():
        for path in conflict_root.glob("*/.*.tmp"):
            if path.stat().st_mtime < stale_before:
                _remove_path(path)

    receipt_dir = cache_root / "receipts"
    artifacts_dir = cache_root / "artifacts"
    entries: List[Dict[str, Any]] = []
    if receipt_dir.is_dir():
        for receipt_path in receipt_dir.glob("*.json"):
            key = receipt_path.stem
            access_path = cache_root / "access" / key
            artifact_name: Optional[str] = None
            artifact_size: Optional[int] = None
            try:
                receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                if _is_cache_poison_record(receipt, key):
                    last_used = (
                        access_path.stat().st_mtime
                        if access_path.is_file() else receipt_path.stat().st_mtime
                    )
                    entries.append({
                        "key": key,
                        "receipt": receipt_path,
                        "access": access_path,
                        "artifact": None,
                        "size": 0,
                        "last_used": last_used,
                    })
                    continue
                if set(receipt) != {
                    "schema", "version", "key", "inputs", "artifact",
                    "artifact_sha256", "artifact_size", "artifact_mode",
                }:
                    raise ValueError("unexpected compiler cache receipt fields")
                artifact_hash = receipt["artifact_sha256"]
                claimed_size = receipt["artifact_size"]
                artifact_mode = receipt["artifact_mode"]
                if (
                    re.fullmatch(r"[0-9a-f]{64}", key) is None
                    or receipt["schema"] != COMPILER_CACHE_SCHEMA
                    or receipt["version"] != COMPILER_CACHE_VERSION
                    or receipt["key"] != key
                    or _compiler_cache_key(receipt["inputs"]) != key
                    or not isinstance(artifact_hash, str)
                    or re.fullmatch(r"[0-9a-f]{64}", artifact_hash) is None
                    or receipt["artifact"] != f"{artifact_hash}.o"
                    or not isinstance(claimed_size, int)
                    or isinstance(claimed_size, bool)
                    or claimed_size < 0
                    or not isinstance(artifact_mode, int)
                    or isinstance(artifact_mode, bool)
                    or artifact_mode < 0
                ):
                    raise ValueError("invalid compiler cache receipt identity")
                artifact_name = receipt["artifact"]
                artifact_path = artifacts_dir / artifact_name
                artifact_stat = artifact_path.stat()
                if (
                    not stat.S_ISREG(artifact_stat.st_mode)
                    or artifact_stat.st_size != claimed_size
                    or stat.S_IMODE(artifact_stat.st_mode) != artifact_mode
                ):
                    raise ValueError("compiler cache artifact metadata mismatch")
                # Capacity accounting trusts the filesystem, never receipt data.
                artifact_size = artifact_stat.st_size
            except (OSError, ValueError, TypeError, KeyError):
                receipt_path.unlink(missing_ok=True)
                access_path.unlink(missing_ok=True)
                continue
            last_used = (
                access_path.stat().st_mtime
                if access_path.is_file() else receipt_path.stat().st_mtime
            )
            entries.append({
                "key": key,
                "receipt": receipt_path,
                "access": access_path,
                "artifact": artifact_name,
                "size": artifact_size,
                "last_used": last_used,
            })
    poison_dir = cache_root / "poisoned"
    if poison_dir.is_dir():
        for poison_path in poison_dir.glob("*.json"):
            key = poison_path.stem
            if re.fullmatch(r"[0-9a-f]{64}", key) is None:
                poison_path.unlink(missing_ok=True)
                continue
            # A poison tombstone dominates any receipt left by an interrupted
            # older implementation.  It is a zero-artifact cache entry with
            # the same LRU/count lifecycle as ordinary receipts.
            for entry in tuple(entries):
                if entry["key"] == key:
                    entry["receipt"].unlink(missing_ok=True)
                    entries.remove(entry)
            access_path = cache_root / "access" / key
            last_used = (
                access_path.stat().st_mtime
                if access_path.is_file() else poison_path.stat().st_mtime
            )
            entries.append({
                "key": key,
                "receipt": poison_path,
                "access": access_path,
                "artifact": None,
                "size": 0,
                "last_used": last_used,
            })
    protected = set(protected_keys)
    entries.sort(
        key=lambda entry: (
            entry["key"] in protected,
            entry["last_used"],
        ),
        reverse=True,
    )
    kept: List[Dict[str, Any]] = []
    kept_artifacts: Dict[str, int] = {}
    total_bytes = 0
    for entry in entries:
        artifact_name = entry["artifact"]
        extra_bytes = 0
        if artifact_name is not None and artifact_name not in kept_artifacts:
            extra_bytes = entry["size"]
        retain = entry["key"] in protected or (
            len(kept) < COMPILER_CACHE_MAX_ENTRIES
            and total_bytes + extra_bytes <= COMPILER_CACHE_MAX_BYTES
        )
        if retain:
            kept.append(entry)
            if artifact_name is not None and artifact_name not in kept_artifacts:
                kept_artifacts[artifact_name] = entry["size"]
                total_bytes += extra_bytes
        else:
            entry["receipt"].unlink(missing_ok=True)
            entry["access"].unlink(missing_ok=True)

    referenced = set(kept_artifacts)
    if artifacts_dir.is_dir():
        for artifact in artifacts_dir.glob("*.o"):
            if artifact.name not in referenced:
                artifact.unlink(missing_ok=True)

    access_dir = cache_root / "access"
    if access_dir.is_dir():
        retained_keys = {entry["key"] for entry in kept}
        for access_path in access_dir.iterdir():
            if access_path.is_file() and access_path.name not in retained_keys:
                access_path.unlink(missing_ok=True)

    _prune_cache_conflicts_locked(cache_root)


def _prune_cache_conflicts_locked(cache_root: Path) -> None:
    conflict_root = cache_root / "conflicts"
    if not conflict_root.is_dir():
        return
    conflicts = sorted(
        conflict_root.glob("*/*.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    for conflict in conflicts[COMPILER_CACHE_MAX_CONFLICTS:]:
        conflict.unlink(missing_ok=True)
    for directory in conflict_root.iterdir():
        if directory.is_dir() and not any(directory.iterdir()):
            directory.rmdir()


def _candidate_anchor(path: Path) -> _CachedAnchor:
    identity = _stable_file_identity(path, include_mode=True)
    return _CachedAnchor(
        path=path,
        sha256=identity["sha256"],
        size=identity["size"],
        mode=identity["mode"],
    )


def _publish_cached_anchor(
    cache_root: Path,
    key: str,
    inputs: Dict[str, Any],
    staged_object: Path,
) -> _CachedAnchor:
    candidate = _candidate_anchor(staged_object)
    if candidate.size > COMPILER_CACHE_MAX_BYTES:
        raise CompilerPreparationError(
            "compiler anchor object exceeds the persistent cache byte limit"
        )
    receipt_path, artifacts_dir = _cache_paths(cache_root, key)
    artifact_path = artifacts_dir / f"{candidate.sha256}.o"
    with _cache_global_lock(cache_root):
        with _cache_key_lock(cache_root, key):
            _reject_poisoned_cache_key_locked(cache_root, key)
            winner = _validated_cached_anchor(cache_root, key, inputs)
            if receipt_path.exists():
                if winner is None:
                    raise CompilerPreparationError(
                        f"compiler cache entry failed validation: {receipt_path}"
                    )
                _cleanup_compiler_cache_locked(
                    cache_root, protected_keys=(key,),
                )
                if not _same_cached_anchor(winner, candidate):
                    poison = _poison_cache_key_locked(
                        cache_root, key, winner, candidate,
                    )
                    evidence = _record_cache_conflict_locked(
                        cache_root, key, winner, candidate,
                    )
                    raise CompilerPreparationError(
                        "same compiler cache key produced divergent anchor objects; "
                        f"poison: {poison}; evidence: {evidence}"
                    )
                _touch_cache_access(cache_root, key)
                return winner

            _cleanup_compiler_cache_locked(cache_root)

            try:
                # Windows rejects fsync on a read-only CRT descriptor even
                # though no bytes are written here.  Open read/write solely to
                # make the durability barrier portable before publication.
                with staged_object.open("r+b") as stream:
                    os.fsync(stream.fileno())
            except OSError as exc:
                raise CompilerPreparationError(
                    f"cannot flush staged compiler anchor object: {exc}"
                ) from exc
            if not artifact_path.exists():
                _hardlink_once(staged_object, artifact_path)
            published = _candidate_anchor(artifact_path)
            if not _same_cached_anchor(published, candidate):
                raise CompilerPreparationError(
                    "content-addressed compiler anchor artifact is inconsistent"
                )
            receipt = {
                "schema": COMPILER_CACHE_SCHEMA,
                "version": COMPILER_CACHE_VERSION,
                "key": key,
                "inputs": inputs,
                "artifact": artifact_path.name,
                "artifact_sha256": candidate.sha256,
                "artifact_size": candidate.size,
                "artifact_mode": candidate.mode,
            }
            if not _create_json_once(receipt_path, receipt):
                winner = _validated_cached_anchor(cache_root, key, inputs)
                if winner is None:
                    raise CompilerPreparationError(
                        f"compiler cache receipt lost its immutable CAS: {receipt_path}"
                )
                if not _same_cached_anchor(winner, candidate):
                    poison = _poison_cache_key_locked(
                        cache_root, key, winner, candidate,
                    )
                    evidence = _record_cache_conflict_locked(
                        cache_root, key, winner, candidate,
                    )
                    raise CompilerPreparationError(
                        "same compiler cache key produced divergent anchor objects; "
                        f"poison: {poison}; evidence: {evidence}"
                    )
                _touch_cache_access(cache_root, key)
                return winner
            winner = _validated_cached_anchor(cache_root, key, inputs)
            if winner is None:
                raise CompilerPreparationError(
                    "published compiler anchor cache entry failed validation"
                )
            _touch_cache_access(cache_root, key)
            _cleanup_compiler_cache_locked(
                cache_root, protected_keys=(key,),
            )
            return winner


def _copy_cached_anchor(source: _CachedAnchor, destination: Path) -> None:
    shutil.copy2(source.path, destination)
    copied = _candidate_anchor(destination)
    if not _same_cached_anchor(source, copied):
        raise CompilerPreparationError(
            "fresh compiler anchor copy failed receipt validation"
        )


def _lookup_cached_anchor(
    cache_root: Path,
    key: str,
    inputs: Dict[str, Any],
    destination: Path,
) -> bool:
    receipt_path, _ = _cache_paths(cache_root, key)
    with _cache_global_lock(cache_root):
        with _cache_key_lock(cache_root, key):
            _reject_poisoned_cache_key_locked(cache_root, key)
            cached = _validated_cached_anchor(cache_root, key, inputs)
            if receipt_path.exists() and cached is None:
                raise CompilerPreparationError(
                    f"compiler cache entry failed validation: {receipt_path}"
                )
            if cached is None:
                _cleanup_compiler_cache_locked(cache_root)
                return False
            _cleanup_compiler_cache_locked(
                cache_root, protected_keys=(key,),
            )
            _copy_cached_anchor(cached, destination)
            _touch_cache_access(cache_root, key)
            return True


def _prepare_compiler(plan: _CompilerBuildPlan) -> str:
    run_dir = Path(tempfile.mkdtemp(prefix="ring_build_"))
    try:
        if not plan.controlled:
            _compile_anchor(plan, run_dir, plan.anchor_source)
            executable = _compile_runtime_and_link(
                plan, run_dir, plan.anchor_source,
            )
        elif not plan.cache_supported or not _compiler_cache_enabled():
            anchor_snapshot = _stage_anchor_snapshot(plan, run_dir)
            _compile_anchor(plan, run_dir, anchor_snapshot)
            executable = _compile_runtime_and_link(
                plan, run_dir, anchor_snapshot,
            )
        else:
            cache_root = COMPILER_ARTIFACT_CACHE
            tracer = _PHASE_TRACER
            cache_root.mkdir(parents=True, exist_ok=True)
            staging_dir = Path(tempfile.mkdtemp(
                prefix=".staging-lookup-", dir=str(cache_root),
            ))
            try:
                anchor_snapshot = _stage_anchor_snapshot(plan, staging_dir)
                inputs = _compiler_cache_inputs(
                    plan, anchor_snapshot, staging_dir,
                )
                key = _compiler_cache_key(inputs)
                run_object = run_dir / "main.o"
                prepare_started_ns = (
                    time.perf_counter_ns() if tracer is not None else None
                )
                hit = _lookup_cached_anchor(
                    cache_root, key, inputs, run_object,
                )
                if hit:
                    if tracer is not None and prepare_started_ns is not None:
                        tracer.record_stage(
                            suite=None,
                            case="runner",
                            stage="compiler_anchor_prepare",
                            duration_ns=(
                                time.perf_counter_ns() - prepare_started_ns
                            ),
                            executed=False,
                            complete=True,
                            outcome="cached",
                        )
                    confirmed_inputs = _compiler_cache_inputs(
                        plan, anchor_snapshot, staging_dir,
                    )
                    if confirmed_inputs != inputs:
                        raise CompilerPreparationError(
                            "compiler anchor cache inputs changed during lookup"
                        )
                else:
                    staged_object = _compile_anchor(
                        plan, staging_dir, anchor_snapshot,
                    )
                    confirmed_inputs = _compiler_cache_inputs(
                        plan, anchor_snapshot, staging_dir,
                    )
                    if confirmed_inputs != inputs:
                        raise CompilerPreparationError(
                            "compiler anchor cache inputs changed during construction"
                        )
                    cached = _publish_cached_anchor(
                        cache_root, key, inputs, staged_object,
                    )
                    _copy_cached_anchor(cached, run_object)
                executable = _compile_runtime_and_link(
                    plan, run_dir, anchor_snapshot,
                )
            finally:
                shutil.rmtree(staging_dir, ignore_errors=True)
    except BaseException:
        shutil.rmtree(run_dir, ignore_errors=True)
        raise
    atexit.register(shutil.rmtree, str(run_dir), True)
    return str(executable)


def find_ring_exe() -> Optional[str]:
    """Prepare the compiler from the tracked C anchor in a fresh run dir."""
    plan = _compiler_build_plan()
    if plan is None:
        return None
    return _prepare_compiler(plan)


def _subprocess_output_text(value: Any) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return "" if value is None else str(value)


def _report_compiler_preparation_failure(exc: BaseException) -> None:
    print("ERROR: failed to build ring.exe from tracked inputs.", file=sys.stderr)
    if isinstance(exc, subprocess.CalledProcessError):
        command = exc.cmd
        if isinstance(command, (list, tuple)):
            command_text = subprocess.list2cmdline([str(arg) for arg in command])
        else:
            command_text = str(command)
        print(
            f"  command exited {exc.returncode}: {command_text}",
            file=sys.stderr,
        )
        for label, value in (("stdout", exc.stdout), ("stderr", exc.stderr)):
            output = _subprocess_output_text(value).rstrip()
            if output:
                print(f"  {label}:", file=sys.stderr)
                print(output, file=sys.stderr)
        return
    if isinstance(exc, subprocess.TimeoutExpired):
        print(f"  command timed out after {exc.timeout}s: {exc.cmd}", file=sys.stderr)
        for label, value in (("stdout", exc.stdout), ("stderr", exc.stderr)):
            output = _subprocess_output_text(value).rstrip()
            if output:
                print(f"  {label}:", file=sys.stderr)
                print(output, file=sys.stderr)
        return
    print(f"  {exc}", file=sys.stderr)


def ensure_runtime(clang: str) -> bool:
    """Build ring_runtime.o from ring_runtime.cpp if missing or stale."""
    tracer = _PHASE_TRACER
    prepare_started_ns = (
        time.perf_counter_ns() if tracer is not None else None
    )
    if not RUNTIME_CPP.is_file():
        if tracer is not None and prepare_started_ns is not None:
            tracer.record_stage(
                suite=None, case="runner", stage="runtime_prepare",
                duration_ns=time.perf_counter_ns() - prepare_started_ns,
                executed=False, complete=False, outcome="missing-input",
            )
        return False
    if RUNTIME_O.is_file():
        if RUNTIME_O.stat().st_mtime >= RUNTIME_CPP.stat().st_mtime:
            if tracer is not None and prepare_started_ns is not None:
                tracer.record_stage(
                    suite=None, case="runner", stage="runtime_prepare",
                    duration_ns=time.perf_counter_ns() - prepare_started_ns,
                    executed=False, complete=True, outcome="cached",
                )
            return True
    cmd = [
        clang, "-c", str(RUNTIME_CPP), "-o", str(RUNTIME_O),
        "-std=c++17", "-O2", "-D_CRT_SECURE_NO_WARNINGS",
    ]
    try:
        # Use clang++ for C++ files -- clang can link C++ but compiling needs
        # the C++ frontend (clang++ or clang -x c++).
        cpp_cmd = list(cmd)
        cpp_compiler = shutil.which("clang++")
        if cpp_compiler:
            cpp_cmd[0] = cpp_compiler
        else:
            # Fall back to clang -x c++
            cpp_cmd = [clang, "-x", "c++"] + cmd[1:]
        _run_subprocess(
            "runtime_prepare", cpp_cmd, check=True, capture_output=True,
            timeout=TIMEOUT_COMPILE, cwd=str(REPO),
        )
        return RUNTIME_O.is_file()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return False


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------

def norm(s: str) -> str:
    """Normalize CRLF to LF."""
    return s.replace("\r\n", "\n")


def matches_filter(name: str, name_filter: Optional[str]) -> bool:
    """Case-insensitive substring match; no filter matches everything.

    Backslashes are normalized to '/' so filters work on Windows.
    """
    if not name_filter:
        return True
    return name_filter.replace("\\", "/").lower() in name.replace("\\", "/").lower()


def normalized_repo_path(path) -> str:
    """Normalize an absolute or repo-relative path to forward-slash form."""
    text = str(path).replace("\\", "/")
    candidate = Path(text)
    if not candidate.is_absolute():
        candidate = REPO / candidate
    return candidate.resolve().relative_to(REPO.resolve()).as_posix()


def _phase_file_identity(path: str) -> str:
    """Return a stable case identity without exposing file contents."""
    try:
        return normalized_repo_path(path)
    except ValueError:
        return Path(path).name


def _phase_relative_identity(path: Path, prefix: str = "") -> str:
    """Return a platform-independent identity for an already-relative case."""
    return prefix + path.as_posix()


def check_blocked_gap_reason(case_path) -> Optional[str]:
    """Return the frontend-blocker reason for a positive case, if any."""
    key = normalized_repo_path(case_path)
    if key in CHECK_BLOCKED_POSITIVE_GAPS:
        return f"known check-blocked positive: {CHECK_BLOCKED_POSITIVE_GAPS[key]}"
    return None


def positive_gap_reason(case_path) -> Optional[str]:
    """Return an execution-gap reason for a positive C-native case, if any."""
    blocked = check_blocked_gap_reason(case_path)
    if blocked:
        return blocked
    key = normalized_repo_path(case_path)
    if key in SHARED_POSITIVE_GAPS:
        return f"known shared positive gap: {SHARED_POSITIVE_GAPS[key]}"
    return None


def is_expect_panic(expected_raw: str) -> bool:
    """Whether the first non-blank expected line requests a non-zero exit."""
    first = next((line.strip() for line in expected_raw.splitlines()
                  if line.strip()), "")
    return first == "// EXPECT_PANIC"


def case_expects_panic(ring_file: Path, expected_raw: str) -> bool:
    """EXPECT_PANIC is valid only for the handwritten native-only lane."""
    return (
        ring_file.resolve().parent == NATIVE_ONLY_DIR.resolve()
        and is_expect_panic(expected_raw)
    )


def expected_panic_diagnostic(expected_raw: str) -> str:
    """Return the optional exact runtime diagnostic after EXPECT_PANIC."""
    lines = norm(expected_raw).splitlines()
    marker_index = next(
        (index for index, line in enumerate(lines) if line.strip()), None)
    if marker_index is None:
        return ""
    return "\n".join(lines[marker_index + 1:]).strip()


# ---------------------------------------------------------------------------
# Compile + link + run helpers
# ---------------------------------------------------------------------------

# Ring diagnostics and program output are UTF-8 contracts.  Windows CI's
# locale may be a legacy code page, so every decoded child-process stream must
# opt into UTF-8 instead of inheriting locale.getpreferredencoding().

def ring_build(ring_exe: str, ring_file: str, *,
               out_dir: Optional[str] = None,
               extra_args: Optional[List[str]] = None,
               timeout: int = TIMEOUT_COMPILE,
               phase_suite: Optional[str] = None,
               phase_case: Optional[str] = None,
               cwd: Optional[Path] = None) -> subprocess.CompletedProcess:
    """Run the C-only ring.exe build with optional extra flags."""
    cmd = [ring_exe, "build", ring_file, "--target=c"]
    if out_dir:
        # Use --out-dir=<path> (equals-sign) form; ring.exe CLI parser does
        # not accept --out-dir <path> as two separate arguments.
        cmd.append(f"--out-dir={out_dir}")
    if extra_args:
        cmd.extend(extra_args)
    if _PHASE_TRACER is not None and phase_case is None:
        phase_case = _phase_file_identity(ring_file)
    return _run_subprocess(
        "ring_build", cmd,
        phase_suite=phase_suite, phase_case=phase_case,
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        timeout=timeout, cwd=str(cwd or REPO),
    )


def ring_check(ring_exe: str, ring_file: str, *,
               extra_args: Optional[List[str]] = None,
               timeout: int = TIMEOUT_COMPILE,
               phase_suite: Optional[str] = None,
               phase_case: Optional[str] = None,
               cwd: Optional[Path] = None) -> subprocess.CompletedProcess:
    """Run ring.exe check <file> [extra_args...]."""
    cmd = [ring_exe, "check", ring_file]
    if extra_args:
        cmd.extend(extra_args)
    if _PHASE_TRACER is not None and phase_case is None:
        phase_case = _phase_file_identity(ring_file)
    return _run_subprocess(
        "ring_check", cmd, phase_suite=phase_suite, phase_case=phase_case,
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        timeout=timeout, cwd=str(cwd or REPO),
    )


def clang_link(clang: str, o_file: str, exe_file: str, *,
               phase_suite: Optional[str] = None,
               phase_case: Optional[str] = None) -> subprocess.CompletedProcess:
    """Link .o + runtime into an executable."""
    cmd = [clang, o_file, str(RUNTIME_O), "-o", exe_file, *CLANG_LINK_FLAGS]
    return _run_subprocess(
        "clang_link", cmd, phase_suite=phase_suite, phase_case=phase_case,
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        timeout=TIMEOUT_LINK, cwd=str(REPO),
    )


def run_exe(exe_path: str, timeout: int = TIMEOUT_RUN, *,
            phase_suite: Optional[str] = None,
            phase_case: Optional[str] = None) -> subprocess.CompletedProcess:
    """Execute a linked test binary."""
    return _run_subprocess(
        "run_exe", [exe_path], phase_suite=phase_suite, phase_case=phase_case,
        capture_output=True, text=True, encoding="utf-8",
        errors="replace", timeout=timeout, cwd=str(REPO),
    )


# ---------------------------------------------------------------------------
# Test-case helpers
# ---------------------------------------------------------------------------

def compile_link_run(ring_exe: str, clang_path: str, ring_file: str,
                     tmpdir: str, *,
                     expect_panic: bool = False,
                     phase_suite: Optional[str] = None,
                     phase_case: Optional[str] = None,
                     cwd: Optional[Path] = None) -> Tuple[bool, str, str]:
    """Compile a .ring file, link, run, return (ok, stdout, error_detail).

    On success, ok=True and stdout contains the program output.
    On failure, ok=False and error_detail describes the failure.

    The C backend compiles with --out-dir=<tmpdir> (contract: emits
    <tmpdir>/<base>.c and <tmpdir>/<base>.o) so no artifacts land next to the
    test sources.
    """
    base = Path(ring_file).stem

    out_dir = tmpdir

    # Compile
    try:
        r = ring_build(
            ring_exe, ring_file, out_dir=out_dir,
            phase_suite=phase_suite, phase_case=phase_case,
            cwd=cwd,
        )
    except subprocess.TimeoutExpired:
        return False, "", "compile timed out"

    if r.returncode != 0:
        return False, "", f"compile failed (exit {r.returncode}): {(r.stderr or r.stdout or '')[:500]}"

    # Locate the .o file
    o_file = os.path.join(out_dir, base + ".o")

    if not os.path.isfile(o_file):
        return False, "", f".o file not found: {o_file}"

    # Link
    exe_file = os.path.join(tmpdir, base + ".exe")
    try:
        r = clang_link(
            clang_path, o_file, exe_file,
            phase_suite=phase_suite, phase_case=phase_case,
        )
    except subprocess.TimeoutExpired:
        return False, "", "link timed out"

    if r.returncode != 0:
        return False, "", f"link failed (exit {r.returncode}): {(r.stderr or '')[:500]}"

    # Run
    try:
        r = run_exe(
            exe_file, phase_suite=phase_suite, phase_case=phase_case,
        )
    except subprocess.TimeoutExpired:
        return False, "", "execution timed out (30s)"

    if expect_panic:
        if r.returncode == 0:
            return False, r.stdout, (
                "expected panic (non-zero exit), but program exited 0: "
                f"{(r.stdout or '')[:300]}"
            )
        return True, (r.stdout or "") + (r.stderr or ""), ""

    if r.returncode != 0:
        return False, "", f"runtime crash (exit {r.returncode}): {(r.stderr or '')[:300]}"

    return True, r.stdout, ""


# ---------------------------------------------------------------------------
# E2E suite
# ---------------------------------------------------------------------------

def discover_positive_cases(directory: Path) -> List[Path]:
    """Return sorted list of .ring files that have a corresponding .expected."""
    if not directory.is_dir():
        return []
    cases = []
    for f in sorted(directory.iterdir()):
        if f.suffix == ".ring" and f.with_suffix(".expected").is_file():
            cases.append(f)
    return cases


def discover_negative_cases(directory: Path) -> List[Path]:
    """Return sorted list of .ring files that have a corresponding .error."""
    if not directory.is_dir():
        return []
    cases = []
    for f in sorted(directory.iterdir()):
        if f.suffix == ".ring" and f.with_suffix(".error").is_file():
            cases.append(f)
    return cases


def error_contract_failure(contract_text: str, output: str) -> Optional[str]:
    """Return why compiler output violates a .error contract, if it does.

    Legacy contracts without a `!` line remain one exact multiline substring.
    Contracts containing `!` treat each non-empty line independently: ordinary
    lines are required substrings and `!pattern` lines are forbidden substrings.
    """
    contract = contract_text.strip()
    if not contract:
        return "malformed .error contract: empty or whitespace-only"

    lines = [line.strip() for line in contract.splitlines() if line.strip()]
    has_forbidden = any(line.startswith("!") for line in lines)
    if has_forbidden:
        required = [line for line in lines if not line.startswith("!")]
        forbidden: List[str] = []
        for line in lines:
            if line.startswith("!"):
                pattern = line[1:].strip()
                if not pattern:
                    return "malformed .error contract: empty forbidden pattern"
                forbidden.append(pattern)
        if not required:
            return (
                "malformed .error contract: forbidden-pattern mode requires "
                "at least one required pattern"
            )
    else:
        required = [contract]
        forbidden = []

    output_lower = output.lower()
    for pattern in required:
        if pattern.lower() not in output_lower:
            return f'missing required diagnostic pattern "{pattern}"'
    for pattern in forbidden:
        if pattern.lower() in output_lower:
            return f'found forbidden diagnostic pattern "{pattern}"'
    return None


def discover_module_positive(modules_dir: Path) -> List[Path]:
    """Return sorted list of module main.ring files that have main.expected."""
    if not modules_dir.is_dir():
        return []
    cases = []
    for d in sorted(modules_dir.iterdir()):
        if d.is_dir():
            main = d / "main.ring"
            expected = d / "main.expected"
            if main.is_file() and expected.is_file():
                cases.append(main)
    return cases


def module_check_positive_census(
    modules_dir: Path,
) -> Tuple[List[Path], List[str]]:
    """Validate every explicit marker before exposing any check-only case."""
    if not modules_dir.is_dir():
        return [], []
    cases: List[Path] = []
    errors: List[str] = []
    markers = sorted(modules_dir.glob("*/main.check"))
    for marker in markers:
        directory = marker.parent
        main = directory / "main.ring"
        expected = directory / "main.expected"
        error = directory / "main.error"
        valid = True
        if marker.is_symlink() or not marker.is_file():
            errors.append(f"{directory.name}: main.check is not a regular file")
            valid = False
        if main.is_symlink() or not main.is_file():
            errors.append(f"{directory.name}: main.check has no sibling main.ring")
            valid = False
        if (
            expected.exists() or expected.is_symlink()
            or error.exists() or error.is_symlink()
        ):
            errors.append(
                f"{directory.name}: main.check overlaps main.expected/main.error")
            valid = False
        try:
            contract = marker.read_bytes()
        except OSError as exc:
            errors.append(f"{directory.name}: cannot read main.check: {exc}")
            valid = False
        else:
            if contract != b"OK\n":
                errors.append(
                    f"{directory.name}: main.check bytes must be exactly OK\\n")
                valid = False
        if valid:
            cases.append(main)
    if errors:
        return [], errors
    return cases, []


def discover_module_check_positive(modules_dir: Path) -> List[Path]:
    """Return cases only after the complete explicit marker census passes."""
    cases, errors = module_check_positive_census(modules_dir)
    return [] if errors else cases


def module_check_positive_discovery_errors(modules_dir: Path) -> List[str]:
    """Validate explicit marker ownership for the generic check-only lane."""
    discovered, errors = module_check_positive_census(modules_dir)
    required = modules_dir / "plan_namespace_empty_growth_cycle" / "main.ring"
    if not errors and required not in discovered:
        errors.append(
            "plan_namespace_empty_growth_cycle is absent from module check-only discovery")
    return errors


def delegate_provider_plan_u1c3_mutation_errors(
    sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    mutations = (
        ("zero-clean child", "env", "make_delegate_child_provider_plan",
         "produced_owner_count == 0 && !had_semantic_error", "false"),
        ("negative owner count", "env", "make_delegate_child_provider_plan",
         "produced_owner_count < 0", "false"),
        ("Final input copy", "env", "delegate_plan_final",
         "copy_delegate_child_provider_plans(children)", "children"),
        ("Final output copy", "env", "delegate_plan_children",
         "copy_delegate_child_provider_plans(children)", "children"),
        ("child count equality", "env", "delegate_child_provider_plan_same",
         "left.produced_owner_count == right.produced_owner_count", "true"),
        ("child error equality", "env", "delegate_child_provider_plan_same",
         "left.had_semantic_error == right.had_semantic_error", "true"),
        ("plan state equality", "env", "delegate_plan_state_same",
         "(DelegatePlanStateValue::DelegatePending,\n"
         "         DelegatePlanStateValue::DelegatePending) => true",
         "(DelegatePlanStateValue::DelegateNotApplicable,\n"
         "         DelegatePlanStateValue::DelegatePending) => true"),
        ("full owner plan equality", "env", "impl_entry_final_same",
         "delegate_plan_state_same(left.delegate_plan, right.delegate_plan)", "true"),
        ("ordered child index", "env", "validate_impl_entry",
         "child.source_member_index <= previous_delegate_index", "false"),
        ("zero-clean validator", "env", "validate_impl_entry",
         "!child.had_semantic_error", "false"),
        ("duplicate child provider", "env", "validate_impl_entry",
         "impl_provider_ref_same(\n                            seen_provider, child.provider_ref)", "false"),
        ("Pending parent kind", "env", "validate_impl_entry",
         "pending delegate plan parent is not Source",
         "pending delegate plan parent kind unchecked"),
        ("unique finalization", "env", "finalize_delegate_provider_plan",
         "if matches != 1", "if false"),
        ("Pending finalization", "env", "finalize_delegate_provider_plan",
         "!delegate_plan_is_pending(entry.delegate_plan)", "false"),
        ("pending close", "env", "assert_no_pending_delegate_plans",
         "delegate_plan_is_pending(owner.delegate_plan)", "false"),
        ("source phase early fact consume", "register", "register_impl",
         "some(Decl::Delegate { .. }) => { has_delegate = true }",
         "some(Decl::Delegate { .. }) => { let _ = peek_delegate_provider_fact(ctx, decl_index, source_member_index); has_delegate = true }"),
        ("source Pending", "register", "register_impl",
         "delegate_plan_pending()", "delegate_plan_final([])"),
        ("phase3 fact consume", "register", "register_phase3_delegate",
         "commit_delegate_provider_fact(ctx, fact)", "{}"),
        ("phase3 parent relation", "register", "register_phase3_delegate",
         "fact.parent_provider_ref, parent_provider_ref", "parent_provider_ref, parent_provider_ref"),
        ("phase3 owner count", "register", "register_phase3_delegate",
         "let produced_owner_count = find_impls_by_provider(",
         "let produced_owner_count = []"),
        ("phase3 local outcome", "register", "register_phase3_delegate",
         "let had_semantic_error = outcome.unwrap_or(true)",
         "let had_semantic_error = false"),
        ("phase3 early finalize", "register", "register_phase3_delegate",
         "let outcome = some(register_delegate(",
         "finalize_delegate_provider_plan(\n"
         "                                ctx.env.trait_reg, canonical_target,\n"
         "                                canonical_trait_ref, parent_provider_ref, []\n"
         "                            )\n"
         "                            let outcome = some(register_delegate("),
        ("manual conflict outcome", "register", "register_delegate_traits",
         "had_semantic_error = true\n                        let _ = type_error(ctx.sink, E0509,",
         "let _ = type_error(ctx.sink, E0509,"),
        ("generated owner state", "register", "register_delegate_traits",
         "delegate_plan: delegate_plan_not_applicable()",
         "delegate_plan: delegate_plan_pending()"),
        ("actual provider query", "decl", "expand_delegate_impls",
         "find_impls_by_provider(", "find_impl("),
        ("owner count drift", "decl", "expand_delegate_impls",
         "produced_owners.len() != produced_owner_count", "false"),
        ("zero local outcome", "decl", "expand_delegate_impls",
         "if had_semantic_error { return result }", "return result"),
        ("global error bypass", "decl", "expand_delegate_impls",
         "if had_semantic_error { return result }",
         "if ctx.sink.has_errors() { return result }"),
        ("outer provider query", "decl", "expand_delegate_impls",
         "find_impl_by_provider(", "find_impl_by_origin("),
        ("raw index call", "decl", "check_one_decl",
         "ctx, hd, source_member_index", "ctx, hd, 0"),
        ("checker missing owner", "checker", "validate_impl_carriers",
         'none => panic("impl HIR: typed owner is missing")',
         "none => {}"),
        ("collector missing owner", "checker", "collect_module_impl_facts",
         "none => panic(", "none => if ctx.sink.has_errors() { {} } else { panic("),
    )
    killed = 0
    for label, source_name, function_name, anchor, replacement in mutations:
        mutated_source, mutation_error = _f0_mutate_function_once(
            sources[source_name], function_name, anchor, replacement)
        if mutation_error:
            errors.append(f"delegate provider mutation {label}: {mutation_error}")
            continue
        assert mutated_source is not None
        mutated = dict(sources)
        mutated[source_name] = mutated_source
        if not delegate_provider_plan_u1c3_contract_errors(mutated):
            errors.append(f"delegate provider mutation escaped: {label}")
        else:
            killed += 1

    env_source = sources["env"]
    child_anchor = "pub struct DelegateChildProviderPlan {\n    source_member_index: Int,"
    if env_source.count(child_anchor) != 1:
        errors.append("delegate child opacity anchor drifted")
    else:
        mutated = dict(sources)
        mutated["env"] = env_source.replace(
            child_anchor,
            "pub struct DelegateChildProviderPlan {\n    pub source_member_index: Int,",
            1)
        if not delegate_provider_plan_u1c3_contract_errors(mutated):
            errors.append("delegate child opacity mutation escaped")
        else:
            killed += 1
    if killed != F2_DELEGATE_PROVIDER_PLAN_MUTATION_COUNT:
        errors.append(
            f"delegate provider killed {killed} mutations, expected "
            f"{F2_DELEGATE_PROVIDER_PLAN_MUTATION_COUNT}")
    return errors


def delegate_provider_plan_u1c3_fixture_errors(ring_exe: str) -> List[str]:
    errors: List[str] = []
    compiler_path = Path(ring_exe).resolve(strict=True)
    compiler = str(compiler_path)
    compiler_before = _sha256_file(compiler_path)
    environment = dict(_controlled_environment(compiler))
    positive = CASES_DIR / "delegate_shared_supertrait_provider.ring"
    negatives = (
        CASES_DIR / "delegate_conflict.ring",
        CASES_DIR / "error_delegate_duplicate_child_provider.ring",
        CASES_DIR / "error_delegate_no_field.ring",
        CASES_DIR / "error_delegate_no_impl.ring",
    )
    if positive not in discover_positive_cases(CASES_DIR):
        errors.append("shared-supertrait delegate fixture is not runner-discovered")
    else:
        positive_error = _f1_run_ring_check(
            compiler, positive, environment)
        if positive_error:
            errors.append(positive_error)
    discovered_negatives = discover_negative_cases(CASES_DIR)
    for negative in negatives:
        if negative not in discovered_negatives:
            errors.append(
                f"delegate negative fixture is not runner-discovered: {negative.name}")
            continue
        try:
            completed = subprocess.run(
                [compiler, "check", str(negative)],
                cwd=REPO, env=environment, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, encoding="utf-8", errors="strict",
                check=False, timeout=120)
        except subprocess.TimeoutExpired:
            errors.append(f"delegate negative timed out: {negative.name}")
            continue
        if completed.returncode == 0:
            errors.append(
                f"delegate negative unexpectedly passed: {negative.name}")
            continue
        contract = negative.with_suffix(".error").read_text(encoding="utf-8")
        combined = (completed.stdout or "") + (completed.stderr or "")
        contract_error = error_contract_failure(contract, combined)
        if contract_error is not None:
            errors.append(
                f"delegate negative contract failed for {negative.name}: "
                f"{contract_error}; output={combined[:300]!r}")
    if _sha256_file(compiler_path) != compiler_before:
        errors.append("pinned Ring compiler changed across delegate fixtures")
    return errors


def delegate_provider_plan_u1c3_source_errors() -> List[str]:
    sources: dict[str, str] = {}
    try:
        for name, path in F2_DELEGATE_PROVIDER_PLAN_PATHS.items():
            sources[name] = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read delegate provider plan sources: {exc}"]
    errors = delegate_provider_plan_u1c3_contract_errors(sources)
    if errors:
        return errors
    errors.extend(delegate_provider_plan_u1c3_mutation_errors(sources))
    return errors


def module_check_positive_discovery_unit_errors() -> List[str]:
    """Exercise overlap and orphan marker rejection without invoking Ring."""
    errors: List[str] = []
    with tempfile.TemporaryDirectory(prefix="ring_module_check_discovery_") as tmp:
        root = Path(tmp)
        orphan = root / "orphan"
        overlap = root / "overlap"
        orphan.mkdir()
        overlap.mkdir()
        (orphan / "main.check").write_bytes(b"OK\n")
        (overlap / "main.ring").write_text("fn main() {}\n", encoding="utf-8")
        (overlap / "main.check").write_bytes(b"OK\n")
        (overlap / "main.expected").write_text("unused\n", encoding="utf-8")
        discovered, findings = module_check_positive_census(root)
    expected = [
        "orphan: main.check has no sibling main.ring",
        "overlap: main.check overlaps main.expected/main.error",
    ]
    if discovered:
        errors.append(
            "invalid marker census exposed check-only cases: "
            + ", ".join(path.parent.name for path in discovered))
    if findings != expected:
        errors.append(
            f"module check-only discovery findings were {findings!r}, "
            f"expected {expected!r}")
    return errors


def discover_module_negative(modules_dir: Path) -> List[Path]:
    """Return sorted list of module main.ring files that have main.error."""
    if not modules_dir.is_dir():
        return []
    cases = []
    for d in sorted(modules_dir.iterdir()):
        if d.is_dir():
            main = d / "main.ring"
            error = d / "main.error"
            if main.is_file() and error.is_file():
                cases.append(main)
    return cases


def run_cli_diagnostic_contracts(
    ring_exe: str,
    collector: ResultCollector,
    *,
    name_filter: Optional[str] = None,
) -> None:
    """Run unique recovery/warning/formatter contracts from the old E2E harness."""
    suite = "e2e"

    def execute(label: str, fixture: Path, args: List[str], validator) -> None:
        fixture_key = normalized_repo_path(fixture)
        if not (
            matches_filter(label, name_filter)
            or matches_filter(fixture_key, name_filter)
        ):
            return
        if not fixture.is_file():
            collector.add(TestResult(
                TestResult.FAIL, suite, label,
                f"diagnostic fixture not found: {fixture_key}",
            ))
            return
        try:
            result = ring_check(
                ring_exe, str(fixture), extra_args=args,
                phase_suite=suite, phase_case=label,
            )
        except subprocess.TimeoutExpired:
            collector.add(TestResult(TestResult.FAIL, suite, label, "check timed out"))
            return
        failure = validator(result)
        collector.add(TestResult(
            TestResult.PASS if failure is None else TestResult.FAIL,
            suite,
            label,
            failure or "",
        ))

    def llm_error(
        result: subprocess.CompletedProcess,
        code: str,
    ) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
        if result.returncode == 0:
            return None, "expected non-zero exit, got 0"
        diagnostics, failure = llm_diagnostics(result.stdout or "")
        if failure is not None or diagnostics is None:
            return None, failure
        diagnostic = diagnostic_by_code(diagnostics, code)
        if diagnostic is None:
            return None, f"expected {code} in LLM diagnostics"
        return diagnostic, None

    def warning_failure(
        result: subprocess.CompletedProcess,
        code: str,
        *,
        llm: bool,
        line: Optional[int] = None,
    ) -> Optional[str]:
        if result.returncode != 0:
            return f"expected warning-only exit 0, got {result.returncode}"
        if "OK" not in (result.stdout or ""):
            return f"expected OK on stdout, got: {(result.stdout or '')[:200]}"
        stderr = result.stderr or ""
        if llm:
            diagnostics, failure = llm_diagnostics(stderr)
            if failure is not None or diagnostics is None:
                return failure
            diagnostic = diagnostic_by_code(diagnostics, code)
            if diagnostic is None or diagnostic.get("severity") != "warning":
                return f"expected warning diagnostic {code} in LLM JSON"
            if line is not None:
                span = diagnostic.get("span")
                if not isinstance(span, dict) or span.get("line") != line:
                    return f"expected {code} span on line {line}, got {span!r}"
            return None
        human = strip_ansi(stderr)
        if f"warning[{code}]" not in human:
            return f"expected warning[{code}] on stderr, got: {human[:300]}"
        if line is not None and f":{line}:" not in human:
            return f"expected {code} source span on line {line}"
        return None

    def recovery_failure(result: subprocess.CompletedProcess) -> Optional[str]:
        if result.returncode == 0:
            return "expected recovered parse/type diagnostics to exit non-zero"
        output = strip_ansi(process_output(result))
        match = re.search(r"\[debug\]\s+parse-recovery\s+decls=(\d+)", output)
        if match is None:
            return "missing '[debug] parse-recovery decls=<N>' marker"
        if int(match.group(1)) < 2:
            return f"expected at least 2 recovered declarations, got {match.group(1)}"
        for code in ("E0103", "E0301"):
            if code not in output:
                return f"expected recovered diagnostic {code}, got: {output[:500]}"
        return None

    def suggestion_human_failure(result: subprocess.CompletedProcess) -> Optional[str]:
        if result.returncode == 0:
            return "expected type mismatch to exit non-zero"
        output = strip_ansi(result.stderr or "")
        for pattern in ("error[E0301]", "help:", "parse_int", "note:", "expected"):
            if pattern not in output:
                return f"human diagnostic omitted {pattern!r}: {output[:500]}"
        return None

    def suggestion_llm_failure(result: subprocess.CompletedProcess) -> Optional[str]:
        diagnostic, failure = llm_error(result, "E0301")
        if failure is not None or diagnostic is None:
            return failure
        if diagnostic.get("category") != "type":
            return f"expected category 'type', got {diagnostic.get('category')!r}"
        suggestions = diagnostic.get("suggestions")
        if not isinstance(suggestions, list) or not suggestions:
            return "expected at least one conversion suggestion"
        if "parse_int" not in " ".join(
            str(item.get("message", "")) for item in suggestions
            if isinstance(item, dict)
        ):
            return "expected parse_int in LLM suggestions"
        notes = diagnostic.get("notes")
        if not isinstance(notes, list) or len(notes) < 2:
            return "expected at least two type-constraint notes"
        first = str(notes[0].get("message", "")) if isinstance(notes[0], dict) else ""
        second = str(notes[1].get("message", "")) if isinstance(notes[1], dict) else ""
        if "expected" not in first or "Int" not in first:
            return f"first constraint note lost expected Int: {first!r}"
        if "Str" not in second:
            return f"second constraint note lost actual Str: {second!r}"
        return None

    def return_notes_failure(result: subprocess.CompletedProcess) -> Optional[str]:
        diagnostic, failure = llm_error(result, "E0301")
        if failure is not None or diagnostic is None:
            return failure
        notes = diagnostic.get("notes")
        if not isinstance(notes, list) or len(notes) < 2:
            return "expected at least two return-type constraint notes"
        text = " ".join(
            str(item.get("message", "")) for item in notes
            if isinstance(item, dict)
        )
        if "return type" not in text and "declared" not in text:
            return f"missing declared return-type note: {text!r}"
        if "body" not in text and "evaluates" not in text:
            return f"missing function-body type note: {text!r}"
        return None

    def empty_list_failure(result: subprocess.CompletedProcess) -> Optional[str]:
        diagnostic, failure = llm_error(result, "E0301")
        if failure is not None or diagnostic is None:
            return failure
        suggestions = diagnostic.get("suggestions")
        if not isinstance(suggestions, list):
            return "expected empty-list suggestions array"
        matching = [
            item for item in suggestions
            if isinstance(item, dict)
            and (
                "type annotation" in str(item.get("message", ""))
                or "List<" in str(item.get("message", ""))
            )
        ]
        if not matching:
            return "expected an empty-list type-annotation suggestion"
        if matching[0].get("replacement") is None:
            return "expected replacement text for empty-list suggestion"
        return None

    def effect_failure(result: subprocess.CompletedProcess) -> Optional[str]:
        diagnostic, failure = llm_error(result, "E0403")
        if failure is not None or diagnostic is None:
            return failure
        notes = diagnostic.get("notes")
        if not isinstance(notes, list):
            return "expected unhandled-effect notes array"
        note_text = " ".join(
            str(item.get("message", "")) for item in notes
            if isinstance(item, dict)
        )
        if "Logger" not in note_text:
            return f"expected Logger in unhandled-effect notes: {note_text!r}"
        suggestions = diagnostic.get("suggestions")
        if not isinstance(suggestions, list) or not suggestions:
            return "expected an unhandled-effect suggestion"
        matching = [
            item for item in suggestions
            if isinstance(item, dict)
            and "handle" in str(item.get("message", "")).lower()
            and "Logger" in str(item.get("message", ""))
        ]
        if not matching:
            return "expected suggestion to handle the Logger effect"
        replacement = matching[0].get("replacement")
        if not isinstance(replacement, str) or "handle" not in replacement:
            return "expected handle replacement in LLM suggestion"
        return None

    def parse_llm_failure(result: subprocess.CompletedProcess) -> Optional[str]:
        if result.returncode == 0:
            return "expected parse errors to exit non-zero"
        diagnostics, failure = llm_diagnostics(result.stdout or "")
        if failure is not None or diagnostics is None:
            return failure
        first_code = diagnostics[0].get("code")
        if not isinstance(first_code, str) or not first_code.startswith("E01"):
            return f"expected first LLM diagnostic to be a parse error, got {first_code!r}"
        return None

    def json_derive_span_failure(
        result: subprocess.CompletedProcess,
    ) -> Optional[str]:
        diagnostic, failure = llm_error(result, "E0503")
        if failure is not None or diagnostic is None:
            return failure
        if diagnostic.get("message") != (
            "Cannot derive Json for 'JsonFieldMissing': every field must "
            "provide Json evidence"
        ):
            return f"unexpected first E0503: {diagnostic.get('message')!r}"
        span = diagnostic.get("span")
        expected = {"line": 4, "col": 0, "end_line": 4, "end_col": 13}
        if span != expected:
            return f"expected exact @derive(Json) span {expected!r}, got {span!r}"
        return None

    def clean_llm_failure(result: subprocess.CompletedProcess) -> Optional[str]:
        if result.returncode != 0:
            return f"expected clean check exit 0, got {result.returncode}"
        if "OK" not in (result.stdout or ""):
            return f"expected OK on stdout, got: {(result.stdout or '')[:200]}"
        if (result.stderr or "").strip():
            return f"clean LLM check emitted diagnostics: {(result.stderr or '')[:300]}"
        return None

    def module_llm_failure(
        result: subprocess.CompletedProcess, code: str,
    ) -> Optional[str]:
        if result.returncode == 0:
            return "expected module diagnostic to exit non-zero"
        diagnostics, failure = module_llm_diagnostics(result.stderr or "")
        if failure is not None or diagnostics is None:
            return failure
        actual = diagnostics[0].get("code")
        if actual != code:
            return f"expected first module diagnostic {code}, got {actual!r}"
        return None

    for recovery_name in RECOVERY_CASES:
        execute(
            f"recovery:{recovery_name}",
            CASES_DIR / recovery_name,
            ["--debug"],
            recovery_failure,
        )

    execute(
        "warning:catch-pure-W0001",
        CASES_DIR / "catch_pure_expr.ring",
        [],
        lambda result: warning_failure(result, "W0001", llm=False),
    )
    execute(
        "warning:where-W0002-human",
        CASES_DIR / "where_clause_warning.ring",
        [],
        lambda result: warning_failure(result, "W0002", llm=False, line=11),
    )
    execute(
        "warning:where-W0002-llm",
        CASES_DIR / "where_clause_warning.ring",
        ["--error-format=llm"],
        lambda result: warning_failure(result, "W0002", llm=True, line=11),
    )
    execute(
        "diagnostic:type-suggestion-human",
        CASES_DIR / "error_with_suggestion.ring",
        [],
        suggestion_human_failure,
    )
    execute(
        "diagnostic:type-suggestion-llm",
        CASES_DIR / "error_with_suggestion.ring",
        ["--error-format=llm"],
        suggestion_llm_failure,
    )
    execute(
        "diagnostic:return-notes-llm",
        CASES_DIR / "error_diagnostic_notes.ring",
        ["--error-format=llm"],
        return_notes_failure,
    )
    execute(
        "diagnostic:empty-list-suggestion-llm",
        CASES_DIR / "error_empty_list_suggestion.ring",
        ["--error-format=llm"],
        empty_list_failure,
    )
    execute(
        "diagnostic:effect-suggestion-llm",
        CASES_DIR / "error_effect_suggestion.ring",
        ["--error-format=llm"],
        effect_failure,
    )
    execute(
        "diagnostic:parse-errors-llm-schema",
        CASES_DIR / "error_multi_parse.ring",
        ["--error-format=llm"],
        parse_llm_failure,
    )
    execute(
        "diagnostic:json-derive-E0503-span-llm",
        CASES_DIR / "error_json_derive_field_missing.ring",
        ["--error-format=llm"],
        json_derive_span_failure,
    )
    execute(
        "diagnostic:clean-check-llm",
        CASES_DIR / "hello.ring",
        ["--error-format=llm"],
        clean_llm_failure,
    )
    execute(
        "diagnostic:module-resolver-E0702-llm",
        MODULES_DIR / "error_not_found" / "main.ring",
        ["--error-format=llm"],
        lambda result: module_llm_failure(result, "E0702"),
    )
    execute(
        "diagnostic:module-checker-E0703-llm",
        MODULES_DIR / "error_symbol_not_found" / "main.ring",
        ["--error-format=llm"],
        lambda result: module_llm_failure(result, "E0703"),
    )


def run_native_real_program_contract(
    ring_exe: str,
    clang_path: str,
    collector: ResultCollector,
    *,
    name_filter: Optional[str] = None,
) -> None:
    """Exercise the production resource plan/certificate once, then run it."""
    suite = "e2e"
    key = "tests/native/real_program.ring"
    label = "native-real-program:resource-planner+certificate"
    if not (
        matches_filter("native-real-program", name_filter)
        or matches_filter(key, name_filter)
        or matches_filter(label, name_filter)
    ):
        return
    if not NATIVE_REAL_PROGRAM.is_file() or not NATIVE_REAL_PROGRAM_EXPECTED.is_file():
        collector.add(TestResult(
            TestResult.FAIL, suite, "native-real-program",
            "real_program.ring or its .expected companion is missing",
        ))
        return

    try:
        result = ring_check(
            ring_exe, str(NATIVE_REAL_PROGRAM),
            phase_suite=suite, phase_case=label,
        )
    except subprocess.TimeoutExpired:
        collector.add(TestResult(TestResult.FAIL, suite, label, "check timed out"))
    else:
        failure = None
        if result.returncode != 0:
            failure = (
                f"expected exit 0, got {result.returncode}: "
                f"{process_output(result)[:300]}"
            )
        elif result.stdout != "OK\n":
            failure = f"expected exact stdout 'OK\\n', got {result.stdout!r}"
        elif result.stderr != "":
            failure = f"expected empty stderr, got {result.stderr!r}"
        collector.add(TestResult(
            TestResult.PASS if failure is None else TestResult.FAIL,
            suite, label, failure or "",
        ))

    expected = norm(NATIVE_REAL_PROGRAM_EXPECTED.read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory(prefix="ring_real_program_") as tmpdir:
        ok, stdout, detail = compile_link_run(
            ring_exe, clang_path, str(NATIVE_REAL_PROGRAM), tmpdir,
            phase_suite=suite,
            phase_case="native-real-program:execute 1/3",
        )
        first_failure = detail if not ok else None
        if ok and norm(stdout) != expected:
            first_failure = f"expected {expected!r}, got {norm(stdout)!r}"
        collector.add(TestResult(
            TestResult.PASS if first_failure is None else TestResult.FAIL,
            suite,
            "native-real-program:execute 1/3",
            first_failure or "",
        ))
        if not ok:
            for run_number in (2, 3):
                collector.add(TestResult(
                    TestResult.FAIL, suite,
                    f"native-real-program:execute {run_number}/3",
                    "first compile/link/run failed",
                ))
            return
        executable = os.path.join(tmpdir, "real_program.exe")
        for run_number in (2, 3):
            label = f"native-real-program:execute {run_number}/3"
            try:
                result = run_exe(
                    executable, phase_suite=suite, phase_case=label,
                )
            except subprocess.TimeoutExpired:
                collector.add(TestResult(TestResult.FAIL, suite, label, "execution timed out"))
                continue
            failure = None
            if result.returncode != 0:
                failure = f"runtime crash (exit {result.returncode}): {(result.stderr or '')[:300]}"
            elif norm(result.stdout or "") != expected:
                failure = f"expected {expected!r}, got {norm(result.stdout or '')!r}"
            collector.add(TestResult(
                TestResult.PASS if failure is None else TestResult.FAIL,
                suite,
                label,
                failure or "",
            ))


def run_e2e(ring_exe: str, clang_path: str, collector: ResultCollector, *,
            name_filter: Optional[str] = None) -> None:
    """Run the E2E test suite."""
    suite = "e2e"

    module_check_errors = module_check_positive_discovery_unit_errors()
    module_check_errors.extend(
        module_check_positive_discovery_errors(MODULES_DIR))
    if module_check_errors:
        for index, error in enumerate(module_check_errors, 1):
            collector.add(TestResult(
                TestResult.FAIL, suite,
                f"module-check-discovery:{index}", error))
        return

    # --- Positive single-file cases ---
    positive = discover_positive_cases(CASES_DIR)
    # Also include cases from subdirectories (negative/, errors/) that have .expected
    for subdir_name in EXTRA_NEG_DIRS:
        subdir = CASES_DIR / subdir_name
        positive.extend(discover_positive_cases(subdir))
    # Hand-written native semantic oracles, including EXPECT_PANIC cases.
    positive.extend(discover_positive_cases(NATIVE_ONLY_DIR))

    with tempfile.TemporaryDirectory(prefix="ring_e2e_") as tmpdir:
        for ring_file in positive:
            name = ring_file.name
            rel = ring_file.relative_to(CASES_DIR)

            if not matches_filter(str(rel), name_filter):
                continue

            gap_reason = positive_gap_reason(ring_file)
            if gap_reason:
                collector.add(TestResult(
                    TestResult.SKIP, suite, str(rel), gap_reason))
                continue

            expected_file = ring_file.with_suffix(".expected")
            expected_raw = expected_file.read_text(encoding="utf-8")
            expect_panic = case_expects_panic(ring_file, expected_raw)
            expected = norm(expected_raw)

            ok, stdout, detail = compile_link_run(ring_exe, clang_path, str(ring_file),
                                                  tmpdir,
                                                  expect_panic=expect_panic,
                                                  phase_suite=suite,
                                                  phase_case=_phase_relative_identity(rel))
            if not ok:
                collector.add(TestResult(TestResult.FAIL, suite, str(rel), detail))
                continue

            if expect_panic:
                diagnostic = expected_panic_diagnostic(expected_raw)
                actual = norm(stdout).strip()
                if diagnostic and actual != diagnostic:
                    collector.add(TestResult(
                        TestResult.FAIL, suite, str(rel),
                        f"expected runtime diagnostic {diagnostic!r}, got {actual!r}"))
                else:
                    detail = (
                        "expected runtime diagnostic observed"
                        if diagnostic else "expected panic observed"
                    )
                    collector.add(TestResult(
                        TestResult.PASS, suite, str(rel), detail))
                continue

            actual = norm(stdout)
            if actual == expected:
                collector.add(TestResult(TestResult.PASS, suite, str(rel)))
            else:
                # Show a concise diff
                exp_repr = repr(expected[:200])
                act_repr = repr(actual[:200])
                collector.add(TestResult(
                    TestResult.FAIL, suite, str(rel),
                    f"expected {exp_repr}, got {act_repr}"))

    # --- Negative single-file cases ---
    negative = discover_negative_cases(CASES_DIR)
    for subdir_name in EXTRA_NEG_DIRS:
        subdir = CASES_DIR / subdir_name
        negative.extend(discover_negative_cases(subdir))

    for ring_file in negative:
        rel = ring_file.relative_to(CASES_DIR)
        name = ring_file.name

        # Negative cases go through `ring check` only -- backend-independent.
        if not matches_filter(str(rel), name_filter):
            continue

        check_key = normalized_repo_path(ring_file)
        if check_key in CHECK_ONLY_GAPS:
            collector.add(TestResult(
                TestResult.SKIP, suite, f"neg:{rel}",
                f"known check-only gap: {CHECK_ONLY_GAPS[check_key]}"))
            continue

        error_file = ring_file.with_suffix(".error")
        contract = error_file.read_text(encoding="utf-8")

        try:
            r = ring_check(
                ring_exe, str(ring_file), phase_suite=suite,
                phase_case=_phase_relative_identity(rel, "neg:"),
            )
        except subprocess.TimeoutExpired:
            collector.add(TestResult(TestResult.FAIL, suite, f"neg:{rel}", "check timed out"))
            continue

        # Check all output (stdout + stderr) against the companion contract.
        combined = (r.stdout or "") + (r.stderr or "")
        contract_failure = normal_diagnostic_contract_failure(
            r, error_contract_failure(contract, combined))
        if contract_failure is None:
            collector.add(TestResult(TestResult.PASS, suite, f"neg:{rel}"))
        else:
            collector.add(TestResult(
                TestResult.FAIL, suite, f"neg:{rel}",
                f"{contract_failure}; output: {combined[:300]}"))

    # --- Module positive ---
    mod_positive = discover_module_positive(MODULES_DIR)
    with tempfile.TemporaryDirectory(prefix="ring_mod_") as tmpdir:
        for main_file in mod_positive:
            mod_name = main_file.parent.name

            if not matches_filter(f"mod:{mod_name}", name_filter):
                continue

            expected_file = main_file.parent / "main.expected"
            expected = norm(expected_file.read_text(encoding="utf-8"))

            # Per-case work dir: module cases all emit "main.o", so a shared
            # directory would let a case that failed to place its artifact
            # silently link a predecessor's main.o and run the wrong binary.
            case_dir = os.path.join(tmpdir, mod_name)
            os.makedirs(case_dir, exist_ok=True)
            ok, stdout, detail = compile_link_run(
                ring_exe, clang_path, str(main_file), case_dir,
                phase_suite=suite, phase_case=f"mod:{mod_name}",
            )
            if not ok:
                collector.add(TestResult(TestResult.FAIL, suite, f"mod:{mod_name}", detail))
                continue

            actual = norm(stdout)
            if actual == expected:
                collector.add(TestResult(TestResult.PASS, suite, f"mod:{mod_name}"))
            else:
                exp_repr = repr(expected[:200])
                act_repr = repr(actual[:200])
                collector.add(TestResult(
                    TestResult.FAIL, suite, f"mod:{mod_name}",
                    f"expected {exp_repr}, got {act_repr}"))

    # --- Explicit module check-only positive ---
    for main_file in discover_module_check_positive(MODULES_DIR):
        mod_name = main_file.parent.name
        label = f"mod-check:{mod_name}"
        if not matches_filter(label, name_filter):
            continue
        try:
            result = ring_check(
                ring_exe, str(main_file), phase_suite=suite,
                phase_case=label)
        except subprocess.TimeoutExpired:
            collector.add(TestResult(
                TestResult.FAIL, suite, label, "check timed out"))
            continue
        failure = None
        if result.returncode != 0:
            failure = f"expected exit 0, got {result.returncode}"
        elif result.stdout != "OK\n":
            failure = f"expected exact stdout 'OK\\n', got {result.stdout!r}"
        elif result.stderr != "":
            failure = f"expected empty stderr, got {result.stderr!r}"
        collector.add(TestResult(
            TestResult.PASS if failure is None else TestResult.FAIL,
            suite, label, failure or ""))

    # --- Module negative ---
    mod_negative = discover_module_negative(MODULES_DIR)
    for main_file in mod_negative:
        mod_name = main_file.parent.name

        # check-only, backend-independent (see single-file negative above)
        if not matches_filter(f"mod-neg:{mod_name}", name_filter):
            continue

        error_file = main_file.parent / "main.error"
        contract = error_file.read_text(encoding="utf-8")

        try:
            r = ring_check(
                ring_exe, str(main_file), phase_suite=suite,
                phase_case=f"mod-neg:{mod_name}",
            )
        except subprocess.TimeoutExpired:
            collector.add(TestResult(TestResult.FAIL, suite, f"mod-neg:{mod_name}", "timed out"))
            continue

        combined = (r.stdout or "") + (r.stderr or "")
        contract_failure = normal_diagnostic_contract_failure(
            r, error_contract_failure(contract, combined))
        if contract_failure is None:
            collector.add(TestResult(TestResult.PASS, suite, f"mod-neg:{mod_name}"))
        else:
            collector.add(TestResult(
                TestResult.FAIL, suite, f"mod-neg:{mod_name}",
                f"{contract_failure}; output: {combined[:300]}"))

    run_cli_diagnostic_contracts(
        ring_exe, collector, name_filter=name_filter,
    )
    run_native_real_program_contract(
        ring_exe, clang_path, collector, name_filter=name_filter,
    )


def run_normal_diagnostic_exit_contract(
    collector: ResultCollector,
    *,
    name_filter: Optional[str] = None,
) -> None:
    """Exercise the shared normal-diagnostic verdict with process results."""
    suite = "ownership-vertical"
    label = "runner:normal-diagnostic-exit"
    if not matches_filter(label, name_filter):
        return

    diagnostic = "error[E0801]: use of moved value: sample\n"
    contract = "E0801\nuse of moved value:\n!internal compiler error"
    failures: List[str] = []
    for returncode, should_pass in (
        (1, True),
        (0, False),
        (-9, False),
        (0xC0000374, False),
    ):
        result = subprocess.CompletedProcess(
            args=["ring", "check"], returncode=returncode,
            stdout=diagnostic, stderr="",
        )
        failure = normal_diagnostic_contract_failure(
            result, error_contract_failure(contract, process_output(result)))
        if (failure is None) != should_pass:
            failures.append(
                f"exit {returncode}: expected "
                f"{'PASS' if should_pass else 'FAIL'}, got {failure or 'PASS'}"
            )
    collector.add(TestResult(
        TestResult.PASS if not failures else TestResult.FAIL,
        suite, label, "; ".join(failures),
    ))


def run_prelude_a1_oracles(
    ring_exe: str, clang_path: str, collector: ResultCollector, *,
    name_filter: Optional[str] = None,
) -> None:
    """Run the four prelude-only A1 acceptance canaries."""
    suite, group = "ownership-vertical", "P-prelude-A1"
    labels = (
        "P1:prelude-self-first", "P2:prelude-mutual-first",
        "P3:prelude-reverse-edge", "P4:prelude-cycle",
    )
    if not any(matches_filter(value, name_filter) for value in (group, *labels)):
        return
    case_dir = CASES_DIR / "prelude_a1"
    probe = case_dir / "probe.ring"

    def overlay(root: Path, name: str, fragments) -> Path:
        cwd, std = root / name, root / name / "std"
        shutil.copytree(REPO / "std", std)
        for target_name, fragment_name in fragments:
            target = std / target_name
            target.write_text(
                target.read_text(encoding="utf-8") + "\n" +
                (case_dir / fragment_name).read_text(encoding="utf-8"),
                encoding="utf-8", newline="\n")
        return cwd

    observed: List[str] = []
    with tempfile.TemporaryDirectory(prefix="ring_prelude_a1_") as tmpdir:
        root = Path(tmpdir)
        for label, fragment in zip(labels[:2], ("self_first.ring", "mutual_first.ring")):
            try:
                cwd = overlay(root, label[:2], (("str.ring", fragment),))
                output = root / f"{label[:2]}-out"
                output.mkdir()
                ok, stdout, detail = compile_link_run(
                    ring_exe, clang_path, str(probe), str(output), cwd=cwd,
                    phase_suite=suite, phase_case=label)
            except (OSError, UnicodeError, subprocess.TimeoutExpired) as exc:
                ok, stdout, detail = False, "", str(exc)
            if ok and norm(stdout) == "P_PRELUDE_A1_OK:3/ring/10\n":
                observed.append(norm(stdout))
                collector.add(TestResult(TestResult.PASS, suite, label))
            else:
                collector.add(TestResult(
                    TestResult.FAIL, suite, label,
                    detail or f"unexpected stdout {stdout!r}"))
        collector.add(TestResult(
            TestResult.PASS if len(observed) == 2 and len(set(observed)) == 1
            else TestResult.FAIL,
            suite, "parity:P-prelude-A1-source-order"))

        negatives = (
            (labels[2], "reverse_early.ring", "reverse_late.ring",
             "prelude_reverse_early' -> 'prelude_reverse_late"),
            (labels[3], "cycle_early.ring", "cycle_late.ring",
             "prelude_cycle_early' -> 'prelude_cycle_late"),
        )
        for label, early, late, expected in negatives:
            try:
                cwd = overlay(root, label[:2], (
                    ("str.ring", early), ("io.ring", late)))
                result = ring_check(
                    ring_exe, str(probe), cwd=cwd,
                    phase_suite=suite, phase_case=label)
                output = process_output(result)
            except (OSError, UnicodeError, subprocess.TimeoutExpired) as exc:
                result, output = None, str(exc)
            passed = (
                result is not None and result.returncode != 0
                and "ring panic: prelude file DAG: reverse edge" in output
                and expected in output and "'$prelude$::str'" in output
            )
            collector.add(TestResult(
                TestResult.PASS if passed else TestResult.FAIL,
                suite, label, "" if passed else output[:300]))

def run_ownership_vertical_suite(
    ring_exe: str,
    clang_path: str,
    collector: ResultCollector,
    *,
    name_filter: Optional[str] = None,
) -> None:
    """Adapt aggregate toolchain helpers to the manifest-owned vertical."""
    suite = "ownership-vertical"

    run_normal_diagnostic_exit_contract(
        collector, name_filter=name_filter)
    run_prelude_a1_oracles(
        ring_exe, clang_path, collector, name_filter=name_filter)

    def add_result(status: str, name: str, detail: str) -> None:
        collector.add(TestResult(status, suite, name, detail))

    def run_internal_canary(canary, label: str) -> ExactPanicObservation:
        entry = CASES_DIR / "ownership_vertical" / canary.input_path
        result = ring_check(
            ring_exe, str(entry), extra_args=[f"--rc-mutate={canary.mutation}"],
            phase_suite=suite, phase_case=label,
        )
        return ExactPanicObservation(
            returncode=result.returncode,
            stdout=result.stdout or "",
            stderr=result.stderr or "",
        )

    context = RunnerContext(
        manifest_path=CASES_DIR / "ownership_vertical" / "manifest.json",
        check=lambda entry, label: ring_check(
            ring_exe, str(entry), phase_suite=suite, phase_case=label),
        native=lambda entry, output_dir, label: compile_link_run(
            ring_exe, clang_path, str(entry), str(output_dir),
            phase_suite=suite, phase_case=label),
        add_result=add_result,
        matches_filter=matches_filter,
        internal_canary=run_internal_canary,
    )
    run_ownership_vertical(context, name_filter=name_filter)


# ---------------------------------------------------------------------------
# Golden-snapshot suite
# ---------------------------------------------------------------------------

def run_golden(ring_exe: str, clang_path: str, collector: ResultCollector,
               *, update_golden: bool = False,
               name_filter: Optional[str] = None) -> None:
    """Run the C-native golden-snapshot regression suite."""
    suite = "golden"
    cases = discover_positive_cases(GOLDEN_CASES_DIR)
    if not cases:
        print(f"WARNING: no golden cases found in {GOLDEN_CASES_DIR}", file=sys.stderr)
        return

    with tempfile.TemporaryDirectory(prefix="ring_golden_") as tmpdir:
        for ring_file in cases:
            name = ring_file.name
            expected_file = ring_file.with_suffix(".expected")

            if not matches_filter(name, name_filter):
                continue

            gap_reason = positive_gap_reason(ring_file)
            if gap_reason:
                collector.add(TestResult(
                    TestResult.SKIP, suite, name, gap_reason))
                continue

            ok, stdout, detail = compile_link_run(ring_exe, clang_path, str(ring_file),
                                                  tmpdir, phase_suite=suite,
                                                  phase_case=name)
            if not ok:
                collector.add(TestResult(TestResult.FAIL, suite, name, detail))
                continue

            actual = norm(stdout)

            if update_golden:
                expected_file.write_text(actual, encoding="utf-8")
                collector.add(TestResult(TestResult.PASS, suite, name, "golden updated"))
                continue

            expected = norm(expected_file.read_text(encoding="utf-8"))
            if actual == expected:
                collector.add(TestResult(TestResult.PASS, suite, name))
            else:
                exp_repr = repr(expected[:200])
                act_repr = repr(actual[:200])
                collector.add(TestResult(
                    TestResult.FAIL, suite, name,
                    f"expected {exp_repr}, got {act_repr}"))


# ---------------------------------------------------------------------------
# Generated-C structural suite (C-native codegen invariants)
# ---------------------------------------------------------------------------

C_LINE_MARKER_RE = re.compile(
    r"\blet\s+(c_line_marker_[a-z][a-z0-9_]*)\b")
C_LINE_DIRECTIVE_RE = re.compile(
    r'#line[ \t]+(?P<line>[0-9]+)[ \t]+"'
    r'(?P<path>(?:\\.|[^"\\])*)"[ \t]*')


def structural_fixture_paths() -> set[str]:
    """Return every .ring fixture owned by the structural suite."""
    if not STRUCTURAL_DIR.is_dir():
        return set()
    return {
        repo_relative(path)
        for path in STRUCTURAL_DIR.rglob("*.ring")
        if path.is_file()
    }


def ring_line_markers(path: Path) -> Tuple[List[Tuple[str, int]], Optional[str]]:
    """Find real-code line markers, ignoring lookalikes in strings/comments."""
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [], f"cannot read {display_path(path)}: {exc}"
    masked = mask_ring_strings_and_comments(source)
    markers = []
    for match in C_LINE_MARKER_RE.finditer(masked):
        line = masked.count("\n", 0, match.start(1)) + 1
        markers.append((match.group(1), line))
    return markers, None


def extract_ring_function_body(
    source: str,
    function_name: str,
) -> Tuple[Optional[str], Optional[str]]:
    """Extract one named Ring fixture function body, ignoring decoy text."""
    masked = mask_ring_strings_and_comments(source)
    pattern = re.compile(
        rf"\bfn\s+{re.escape(function_name)}\s*"
        rf"\([^{{}}]*\)[^{{}}\n]*\{{")
    matches = list(pattern.finditer(masked))
    if len(matches) != 1:
        return None, f"Ring function {function_name} found {len(matches)} times"
    open_index = masked.rfind("{", matches[0].start(), matches[0].end())
    try:
        close_index = matching_delimiter(masked, open_index, "{", "}")
    except ValueError as exc:
        return None, f"Ring function {function_name}: {exc}"
    return source[open_index + 1:close_index], None


EXTERN_FIXTURE_CONTRACTS = (
    (
        "raw extern type",
        r"\bextern\s+type\s+StructuralRawHandle\b",
    ),
    (
        "raw/owned holder field order",
        r"\bstruct\s+StructuralHolder\s*\{\s*"
        r"raw\s*:\s*StructuralRawHandle\s*,\s*owned\s*:\s*Str\s*\}",
    ),
    (
        "raw/owned enum variant order",
        r"\benum\s+StructuralChoice\s*\{\s*"
        r"Raw\s*\(\s*StructuralRawHandle\s*\)\s*,\s*"
        r"Owned\s*\(\s*Str\s*\)\s*\}",
    ),
    (
        "raw identity parameter",
        r"\bfn\s+structural_raw_identity\s*\(\s*"
        r"value\s*:\s*StructuralRawHandle\s*\)\s*->\s*"
        r"StructuralRawHandle\b",
    ),
    (
        "owned identity parameter",
        r"\bfn\s+structural_owned_identity\s*\(\s*"
        r"value\s*:\s*Str\s*\)\s*->\s*Str\b",
    ),
    (
        "raw Option parameter",
        r"\bfn\s+structural_raw_option\s*\(\s*"
        r"value\s*:\s*StructuralRawHandle\s*\)",
    ),
    (
        "owned Option parameter",
        r"\bfn\s+structural_owned_option\s*\(\s*"
        r"value\s*:\s*Str\s*\)",
    ),
    (
        "raw List parameter",
        r"\bfn\s+structural_raw_list\s*\(\s*"
        r"value\s*:\s*StructuralRawHandle\s*\)",
    ),
    (
        "owned List parameter",
        r"\bfn\s+structural_owned_list\s*\(\s*"
        r"value\s*:\s*Str\s*\)",
    ),
    (
        "non-executing main",
        r"\bfn\s+main\s*\(\s*\)\s*\{\s*\}",
    ),
)

EXTERN_FUNCTION_BODY_CONTRACTS = {
    "structural_raw_identity": (
        r"\A\s*let\s+local\s*=\s*value\s+local\s*\Z"),
    "structural_owned_identity": (
        r"\A\s*let\s+local\s*=\s*value\s+local\s*\Z"),
    "structural_raw_option": (
        r"\A\s*let\s+wrapped\s*=\s*some\s*\(\s*value\s*\)\s*\Z"),
    "structural_owned_option": (
        r"\A\s*let\s+wrapped\s*=\s*some\s*\(\s*value\s*\)\s*\Z"),
    "structural_raw_list": (
        r"\A\s*let\s+mut\s+values\s*:\s*"
        r"List\s*<\s*StructuralRawHandle\s*>\s*=\s*\[\s*\]\s+"
        r"values\s*\.\s*push\s*\(\s*value\s*\)\s*\Z"),
    "structural_owned_list": (
        r"\A\s*let\s+mut\s+values\s*:\s*"
        r"List\s*<\s*Str\s*>\s*=\s*\[\s*\]\s+"
        r"values\s*\.\s*push\s*\(\s*value\s*\)\s*\Z"),
}


def extern_fixture_source_errors(extern_source: str) -> List[str]:
    """Validate that every named fixture body still performs its probe."""
    errors: List[str] = []
    masked = mask_ring_strings_and_comments(extern_source)
    for description, pattern in EXTERN_FIXTURE_CONTRACTS:
        count = len(re.findall(pattern, masked))
        if count != 1:
            errors.append(
                f"{EXTERN_RC_FIXTURE}: {description} contract matched "
                f"{count} times (expected 1)")
    for function_name, body_pattern in EXTERN_FUNCTION_BODY_CONTRACTS.items():
        body, extract_error = extract_ring_function_body(
            extern_source, function_name)
        if extract_error:
            errors.append(f"{EXTERN_RC_FIXTURE}: {extract_error}")
            continue
        masked_body = mask_ring_strings_and_comments(body)
        if re.fullmatch(body_pattern, masked_body) is None:
            errors.append(
                f"{EXTERN_RC_FIXTURE}: {function_name} body no longer "
                "matches its exact structural probe")
    return errors


def structural_fixture_integrity_errors() -> List[str]:
    """Enforce fixture-to-oracle closure before either runner consumes it."""
    errors: List[str] = []
    actual = structural_fixture_paths()
    configured = [
        fixture
        for fixtures in STRUCTURAL_ORACLE_FIXTURES.values()
        for fixture in fixtures
    ]
    configured_set = set(configured)

    duplicates = sorted({path for path in configured if configured.count(path) > 1})
    if duplicates:
        errors.append(
            "structural fixtures mapped to multiple oracles: "
            + ", ".join(duplicates))
    missing = sorted(configured_set - actual)
    orphan = sorted(actual - configured_set)
    if missing:
        errors.append("structural oracle fixtures missing: " + ", ".join(missing))
    if orphan:
        errors.append("structural fixtures without oracle: " + ", ".join(orphan))

    marker_ids: dict[str, str] = {}
    for case_name, entry, fixtures in C_LINE_BUILD_CASES:
        if entry not in fixtures:
            errors.append(f"{case_name}: build entry is absent from fixture bundle")
        case_markers: List[Tuple[str, int, str]] = []
        for fixture in fixtures:
            path = REPO / fixture
            markers, error = ring_line_markers(path)
            if error:
                errors.append(error)
                continue
            case_markers.extend(
                (marker_id, line, fixture) for marker_id, line in markers)
        if len(case_markers) != 1:
            errors.append(
                f"{case_name}: expected exactly one real-code c_line_marker_ "
                f"declaration across its fixture bundle, found {len(case_markers)}")
            continue
        marker_id, line, fixture = case_markers[0]
        if marker_id in marker_ids:
            errors.append(
                f"duplicate structural marker id {marker_id}: "
                f"{marker_ids[marker_id]} and {fixture}")
        marker_ids[marker_id] = fixture
        if line < 1:
            errors.append(f"{fixture}: marker {marker_id} has invalid line {line}")

    extern_path = REPO / EXTERN_RC_FIXTURE
    try:
        extern_source = extern_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        errors.append(f"cannot read {EXTERN_RC_FIXTURE}: {exc}")
    else:
        errors.extend(extern_fixture_source_errors(extern_source))

    # Json enum metadata mismatch is an internal compiler invariant that cannot
    # be triggered by a well-formed source fixture. Keep a source-level oracle:
    # codegen must fail while compiling and must never invent declaration-order
    # tags for a missing CEnumVariantInfo entry.
    try:
        codegen_source = CODEGEN_C_SOURCE.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        errors.append(f"cannot read {display_path(CODEGEN_C_SOURCE)}: {exc}")
    else:
        masked_codegen = mask_ring_strings_and_comments(codegen_source)
        if re.search(r"\bfallback_tag\b", masked_codegen):
            errors.append("Json enum codegen still contains fallback_tag")
        fail_loud = re.search(
            r"enum_info\.variants\.get\s*\(\s*variant\.name\s*\)"
            r"[\s\S]{0,240}?none\s*=>\s*panic\s*\(",
            masked_codegen,
        )
        if fail_loud is None:
            errors.append(
                "Json enum missing-variant metadata is not compile-time fail-loud")

    return errors


def mask_c_strings_and_comments(source: str) -> str:
    """Blank C strings, character literals, and comments, preserving offsets."""
    masked: List[str] = []
    state = "code"
    index = 0
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""

        if state == "code":
            if char == "/" and next_char == "/":
                masked.extend([" ", " "])
                index += 2
                state = "line-comment"
            elif char == "/" and next_char == "*":
                masked.extend([" ", " "])
                index += 2
                state = "block-comment"
            elif char == '"':
                masked.append(" ")
                index += 1
                state = "string"
            elif char == "'":
                masked.append(" ")
                index += 1
                state = "char"
            else:
                masked.append(char)
                index += 1
            continue

        if state == "line-comment":
            if char == "\n":
                masked.append("\n")
                state = "code"
            else:
                masked.append(" ")
            index += 1
            continue

        if state == "block-comment":
            if char == "*" and next_char == "/":
                masked.extend([" ", " "])
                index += 2
                state = "code"
            else:
                masked.append("\n" if char == "\n" else " ")
                index += 1
            continue

        # String/character literal. Escapes keep both bytes inside the literal.
        quote = '"' if state == "string" else "'"
        if char == "\\" and next_char:
            masked.append(" ")
            masked.append("\n" if next_char == "\n" else " ")
            index += 2
        elif char == quote:
            masked.append(" ")
            index += 1
            state = "code"
        else:
            masked.append("\n" if char == "\n" else " ")
            index += 1

    return "".join(masked)


def matching_delimiter(masked: str, open_index: int,
                       opening: str, closing: str) -> int:
    """Return the matching delimiter index in already-masked C text."""
    if open_index >= len(masked) or masked[open_index] != opening:
        raise ValueError(f"expected {opening!r} at offset {open_index}")
    depth = 0
    for index in range(open_index, len(masked)):
        char = masked[index]
        if char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if depth == 0:
                return index
    raise ValueError(f"unclosed {opening!r} at offset {open_index}")


def extract_c_function_body(c_source: str, symbol: str) -> Tuple[Optional[str], Optional[str]]:
    """Extract one exact generated C function body using its definition symbol."""
    masked = mask_c_strings_and_comments(c_source)
    pattern = re.compile(
        rf"(?m)^[ \t]*(?:(?:static|extern)[ \t]+)?void[ \t]*\*?[ \t]+"
        rf"{re.escape(symbol)}[ \t]*\([^;{{}}\n]*\)[ \t]*\{{")
    matches = list(pattern.finditer(masked))
    if len(matches) != 1:
        return None, f"generated function {symbol} found {len(matches)} times"
    open_index = masked.rfind("{", matches[0].start(), matches[0].end())
    try:
        close_index = matching_delimiter(masked, open_index, "{", "}")
    except ValueError as exc:
        return None, f"generated function {symbol}: {exc}"
    return c_source[open_index + 1:close_index], None


@dataclass(frozen=True)
class IdentityLedgerEvent:
    event_id: int
    kind: str
    edge_id: int
    load_id: int
    parent_frame: str
    child_frame: str
    domain: str
    def_id: int
    canonical_key: str
    producer: str
    source_slot: str
    dest_slot: str
    index: int
    arity: int


_LEDGER_KINDS = {
    "capture-extract", "capture-store", "closure-edge",
    "dict-receiver-load", "effect-receiver-load", "closure-call",
}
_LEDGER_ESCAPES = {"25": "%", "7C": "|", "0A": "\n", "0D": "\r"}


def identity_ledger_event_shape_errors(
    event: IdentityLedgerEvent,
) -> List[str]:
    errors: List[str] = []
    if event.domain == "exact":
        if (
            event.def_id == -1 or not event.canonical_key
            or event.producer
        ):
            errors.append(f"exact event {event.event_id} has malformed shape")
    elif event.domain in {"name-only", "static"}:
        if (
            event.def_id != -1 or not event.canonical_key
            or event.producer
        ):
            errors.append(
                f"keyed event {event.event_id} has malformed {event.domain} shape")
    elif event.domain in {"computed", "fresh"}:
        if (
            event.def_id != -1 or event.canonical_key
            or not event.producer
        ):
            errors.append(
                f"produced event {event.event_id} has malformed {event.domain} shape")
    else:
        errors.append(f"unknown event domain {event.domain!r}")

    if event.kind == "closure-edge":
        if (
            event.domain != "fresh"
            or event.producer != f"closure-edge:{event.child_frame}"
        ):
            errors.append(
                f"closure edge {event.event_id} lacks exact Fresh provenance")
    elif event.kind in {"capture-store", "capture-extract"}:
        if event.domain not in {"exact", "name-only"}:
            errors.append(f"capture {event.event_id} has {event.domain} domain")
    elif event.kind == "dict-receiver-load":
        if event.domain not in {"name-only", "static", "computed"}:
            errors.append(
                f"dict receiver {event.event_id} has {event.domain} domain")
    elif event.kind == "effect-receiver-load":
        if event.domain not in {"name-only", "computed"}:
            errors.append(
                f"effect receiver {event.event_id} has {event.domain} domain")
    elif event.kind == "closure-call":
        if event.domain not in {"exact", "name-only", "computed"}:
            errors.append(
                f"closure call {event.event_id} has {event.domain} domain")
        elif event.domain in {"exact", "name-only"}:
            if event.load_id != 0:
                errors.append(
                    f"slot closure call {event.event_id} carries a load id")
        else:
            receiver_load = event.producer in {
                "dict-receiver-load", "effect-receiver-load",
            }
            if event.load_id > 0 and not receiver_load:
                errors.append(
                    f"loaded closure call {event.event_id} has wrong producer")
            if event.load_id <= 0 and (
                event.load_id < 0 or receiver_load
            ):
                errors.append(
                    f"computed closure call {event.event_id} has wrong load shape")
    else:
        errors.append(f"unknown event kind {event.kind!r}")
    return errors


def _ledger_escape(value: str) -> str:
    return (value.replace("%", "%25").replace("|", "%7C")
            .replace("\n", "%0A").replace("\r", "%0D"))


def _ledger_unescape(value: str) -> str:
    result: List[str] = []
    index = 0
    while index < len(value):
        if value[index] != "%":
            result.append(value[index])
            index += 1
            continue
        if index + 2 >= len(value):
            raise ValueError("truncated ledger escape")
        code = value[index + 1:index + 3]
        decoded = _LEDGER_ESCAPES.get(code)
        if decoded is None:
            raise ValueError(f"unknown ledger escape %{code}")
        result.append(decoded)
        index += 3
    decoded_value = "".join(result)
    if _ledger_escape(decoded_value) != value:
        raise ValueError("non-canonical ledger escape")
    return decoded_value


def serialize_identity_ledger(events: Sequence[IdentityLedgerEvent]) -> bytes:
    lines = ["RING-C-IDENTITY-LEDGER|1"]
    for event in events:
        lines.append("|".join((
            "E", str(event.event_id), _ledger_escape(event.kind),
            str(event.edge_id), str(event.load_id),
            _ledger_escape(event.parent_frame), _ledger_escape(event.child_frame),
            _ledger_escape(event.domain), str(event.def_id),
            _ledger_escape(event.canonical_key), _ledger_escape(event.producer),
            _ledger_escape(event.source_slot), _ledger_escape(event.dest_slot),
            str(event.index), str(event.arity),
        )))
    return ("\n".join(lines) + "\n").encode("utf-8")


def parse_identity_ledger(
    data: bytes,
) -> Tuple[Optional[Tuple[IdentityLedgerEvent, ...]], List[str]]:
    errors: List[str] = []
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        return None, [f"identity ledger is not UTF-8: {exc}"]
    if not text.endswith("\n"):
        errors.append("identity ledger lacks final newline")
    lines = text.splitlines()
    if not lines or lines[0] != "RING-C-IDENTITY-LEDGER|1":
        return None, ["identity ledger header/version mismatch"]
    events: List[IdentityLedgerEvent] = []
    for ordinal, line in enumerate(lines[1:], 1):
        fields = line.split("|")
        if len(fields) != 15 or fields[0] != "E":
            errors.append(
                f"identity ledger line {ordinal} has {len(fields)} fields")
            continue
        try:
            event = IdentityLedgerEvent(
                event_id=int(fields[1]),
                kind=_ledger_unescape(fields[2]),
                edge_id=int(fields[3]),
                load_id=int(fields[4]),
                parent_frame=_ledger_unescape(fields[5]),
                child_frame=_ledger_unescape(fields[6]),
                domain=_ledger_unescape(fields[7]),
                def_id=int(fields[8]),
                canonical_key=_ledger_unescape(fields[9]),
                producer=_ledger_unescape(fields[10]),
                source_slot=_ledger_unescape(fields[11]),
                dest_slot=_ledger_unescape(fields[12]),
                index=int(fields[13]),
                arity=int(fields[14]),
            )
        except (ValueError, TypeError) as exc:
            errors.append(f"identity ledger line {ordinal}: {exc}")
            continue
        events.append(event)
    if errors:
        return None, errors
    relation_errors = validate_identity_ledger_relations(events)
    if relation_errors:
        return None, relation_errors
    if serialize_identity_ledger(events) != data:
        return None, ["identity ledger bytes are not canonical/deterministic"]
    return tuple(events), []


def validate_identity_ledger_relations(
    events: Sequence[IdentityLedgerEvent],
) -> List[str]:
    errors: List[str] = []
    edges: dict[int, IdentityLedgerEvent] = {}
    stores: dict[Tuple[int, int], IdentityLedgerEvent] = {}
    extracts: dict[Tuple[int, int], IdentityLedgerEvent] = {}
    loads: dict[int, IdentityLedgerEvent] = {}
    load_calls: dict[int, List[IdentityLedgerEvent]] = {}
    exact_slots: set[Tuple[str, str]] = set()
    name_only_slots: set[Tuple[str, str]] = set()

    for expected_id, event in enumerate(events, 1):
        if event.event_id != expected_id:
            errors.append(
                f"event order/id drift {event.event_id} != {expected_id}")
        errors.extend(identity_ledger_event_shape_errors(event))
        if event.kind not in _LEDGER_KINDS:
            continue

        if event.kind == "closure-edge":
            if (
                event.edge_id <= 0 or not event.parent_frame
                or not event.child_frame or not event.source_slot
                or not event.dest_slot
            ):
                errors.append(f"malformed closure edge {event.event_id}")
            if event.edge_id in edges:
                errors.append(f"duplicate closure edge {event.edge_id}")
            edges[event.edge_id] = event
        elif event.kind in {"capture-store", "capture-extract"}:
            if (
                event.edge_id <= 0 or event.index <= 0
                or not event.source_slot or not event.dest_slot
            ):
                errors.append(f"capture {event.event_id} has invalid edge/index")
            key = (event.edge_id, event.index)
            target = stores if event.kind == "capture-store" else extracts
            if key in target:
                errors.append(f"duplicate {event.kind} {key}")
            target[key] = event
            if event.kind == "capture-store":
                identity_slot = (event.parent_frame, event.source_slot)
            else:
                identity_slot = (event.child_frame, event.dest_slot)
            if event.domain == "exact":
                exact_slots.add(identity_slot)
            elif event.domain == "name-only":
                name_only_slots.add(identity_slot)
        elif event.kind in {"dict-receiver-load", "effect-receiver-load"}:
            if (
                event.load_id <= 0 or event.index <= 0
                or not event.parent_frame or not event.source_slot
                or not event.dest_slot
            ):
                errors.append(f"receiver load {event.event_id} has invalid id/index")
            if event.load_id in loads:
                errors.append(f"duplicate receiver load {event.load_id}")
            loads[event.load_id] = event
            if event.domain == "exact":
                exact_slots.add((event.parent_frame, event.source_slot))
            if event.domain == "name-only":
                name_only_slots.add((event.parent_frame, event.source_slot))
        elif event.kind == "closure-call":
            if (
                event.arity <= 0 or not event.parent_frame
                or not event.source_slot or not event.dest_slot
            ):
                errors.append(f"closure call {event.event_id} has invalid arity")
            if event.load_id > 0:
                load_calls.setdefault(event.load_id, []).append(event)
            if event.domain == "exact":
                exact_slots.add((event.parent_frame, event.source_slot))
            if event.domain == "name-only":
                name_only_slots.add((event.parent_frame, event.source_slot))

    for key, store in stores.items():
        extract = extracts.get(key)
        if extract is None:
            errors.append(f"capture store {key} has no extract")
            continue
        if (
            store.domain, store.def_id, store.canonical_key, store.producer
        ) != (
            extract.domain, extract.def_id, extract.canonical_key,
            extract.producer,
        ):
            errors.append(f"capture identity mismatch {key}")
        edge = edges.get(store.edge_id)
        if edge is None:
            errors.append(f"capture {key} references missing edge")
        elif (
            store.dest_slot != edge.source_slot
            or store.parent_frame != edge.parent_frame
            or store.child_frame != edge.child_frame
            or extract.parent_frame != edge.parent_frame
            or extract.child_frame != edge.child_frame
        ):
            errors.append(f"capture frame/edge mismatch {key}")
    for key in extracts:
        if key not in stores:
            errors.append(f"capture extract {key} has no store")
    for edge_id in edges:
        store_indices = sorted(index for edge, index in stores if edge == edge_id)
        extract_indices = sorted(index for edge, index in extracts if edge == edge_id)
        expected = list(range(1, len(store_indices) + 1))
        if store_indices != expected or extract_indices != expected:
            errors.append(
                f"edge {edge_id} capture indices drifted: "
                f"{store_indices}/{extract_indices}")
    for load_id, load in loads.items():
        calls = load_calls.get(load_id, [])
        if len(calls) != 1:
            errors.append(f"receiver load {load_id} consumed {len(calls)} times")
        elif (
            calls[0].parent_frame != load.parent_frame
            or calls[0].source_slot != load.dest_slot
            or calls[0].domain != "computed"
            or calls[0].producer != load.kind
        ):
            errors.append(f"receiver load/call slot mismatch {load_id}")
    for load_id in load_calls:
        if load_id not in loads:
            errors.append(f"closure call references missing load {load_id}")
    aliases = exact_slots & name_only_slots
    if aliases:
        errors.append(
            f"exact/name-only owned-slot alias: {sorted(aliases)}")
    return errors


def identity_ledger_mutation_matrix_errors() -> List[str]:
    """Every registered ledger corruption must be killed without C parsing."""
    events = [
        IdentityLedgerEvent(1, "capture-extract", 1, 0, "parent", "child_a",
                            "exact", 41, "x", "", "env", "r_exact_a", 1, 0),
        IdentityLedgerEvent(2, "capture-extract", 2, 0, "parent", "child_b",
                            "exact", 41, "x", "", "env", "r_exact_b", 1, 0),
        IdentityLedgerEvent(3, "capture-store", 1, 0, "parent", "child_a",
                            "exact", 41, "x", "", "r_shared", "t_env_a", 1, 0),
        IdentityLedgerEvent(4, "capture-store", 2, 0, "parent", "child_b",
                            "exact", 41, "x", "", "r_shared", "t_env_b", 1, 0),
        IdentityLedgerEvent(5, "closure-edge", 1, 0, "parent", "child_a",
                            "fresh", -1, "", "closure-edge:child_a",
                            "t_env_a", "t_cl_a", 0, 0),
        IdentityLedgerEvent(6, "closure-edge", 2, 0, "parent", "child_b",
                            "fresh", -1, "", "closure-edge:child_b",
                            "t_env_b", "t_cl_b", 0, 0),
        IdentityLedgerEvent(7, "dict-receiver-load", 0, 1, "child_a", "",
                            "name-only", -1, "__ring_T_Ord", "",
                            "r_shared", "t_method", 1, 0),
        IdentityLedgerEvent(8, "closure-call", 0, 1, "child_a", "",
                            "computed", -1, "", "dict-receiver-load",
                            "t_method", "t_result", 0, 2),
        IdentityLedgerEvent(9, "effect-receiver-load", 0, 2, "child_b", "",
                            "name-only", -1, "__ring_ev_E", "",
                            "r_effect", "t_effect", 1, 0),
        IdentityLedgerEvent(10, "closure-call", 0, 2, "child_b", "",
                            "computed", -1, "", "effect-receiver-load",
                            "t_effect", "t_effect_result", 0, 2),
        IdentityLedgerEvent(11, "dict-receiver-load", 0, 3, "parent", "",
                            "static", -1, "__Int_Ord", "",
                            "ring___Int_Ord", "t_static", 1, 0),
        IdentityLedgerEvent(12, "closure-call", 0, 3, "parent", "",
                            "computed", -1, "", "dict-receiver-load",
                            "t_static", "t_static_result", 0, 2),
        IdentityLedgerEvent(13, "dict-receiver-load", 0, 4, "parent", "",
                            "computed", -1, "", "wrapped-dict:Int:Ord",
                            "t_wrapped", "t_wrapped_method", 1, 0),
        IdentityLedgerEvent(14, "closure-call", 0, 4, "parent", "",
                            "computed", -1, "", "dict-receiver-load",
                            "t_wrapped_method", "t_wrapped_result", 0, 2),
        IdentityLedgerEvent(15, "closure-call", 0, 0, "parent", "",
                            "exact", 41, "x", "", "r_shared", "t_exact", 0, 1),
        IdentityLedgerEvent(16, "closure-call", 0, 0, "parent", "",
                            "name-only", -1, "__ring_T_Ord", "",
                            "r___ring_T_Ord", "t_name", 0, 1),
        IdentityLedgerEvent(17, "closure-call", 0, 0, "parent", "",
                            "computed", -1, "", "expression-closure",
                            "t_expr", "t_computed", 0, 1),
    ]
    errors: List[str] = []
    parsed, valid_errors = parse_identity_ledger(
        serialize_identity_ledger(events))
    if valid_errors or parsed is None:
        return ["valid identity ledger fixture rejected: " + "; ".join(valid_errors)]

    mutations: Tuple[Tuple[str, Callable[[List[IdentityLedgerEvent]], None]], ...] = (
        ("missing store", lambda rows: rows.pop(2)),
        ("duplicate event", lambda rows: rows.insert(1, rows[0])),
        ("swap domain", lambda rows: rows.__setitem__(2, replace(
            rows[2], domain="name-only", def_id=-1, canonical_key="x"))),
        ("wrong DefId", lambda rows: rows.__setitem__(0, replace(
            rows[0], def_id=99))),
        ("wrong key", lambda rows: rows.__setitem__(0, replace(
            rows[0], canonical_key="wrong"))),
        ("Exact sentinel DefId", lambda rows: rows.__setitem__(0, replace(
            rows[0], def_id=-1))),
        ("Exact producer", lambda rows: rows.__setitem__(0, replace(
            rows[0], producer="forged"))),
        ("wrong index", lambda rows: rows.__setitem__(2, replace(
            rows[2], index=2))),
        ("same-frame cross-domain slot alias", lambda rows: rows.__setitem__(0,
            replace(rows[0], dest_slot="r_shared"))),
        ("wrong closure env", lambda rows: rows.__setitem__(2, replace(
            rows[2], dest_slot="t_env_b"))),
        ("store parent frame", lambda rows: rows.__setitem__(2, replace(
            rows[2], parent_frame="wrong_parent"))),
        ("store child frame", lambda rows: rows.__setitem__(2, replace(
            rows[2], child_frame="wrong_child"))),
        ("extract parent frame", lambda rows: rows.__setitem__(0, replace(
            rows[0], parent_frame="wrong_parent"))),
        ("extract child frame", lambda rows: rows.__setitem__(0, replace(
            rows[0], child_frame="wrong_child"))),
        ("wrong edge", lambda rows: rows.__setitem__(2, replace(
            rows[2], edge_id=2))),
        ("sibling cross-pair", lambda rows: rows.__setitem__(0, replace(
            rows[0], edge_id=2))),
        ("dict exact domain", lambda rows: rows.__setitem__(6, replace(
            rows[6], domain="exact", def_id=73, canonical_key="dict_local"))),
        ("dict effect-only domain", lambda rows: rows.__setitem__(6, replace(
            rows[6], domain="fresh", canonical_key="",
            producer="forged-dict"))),
        ("effect exact domain", lambda rows: rows.__setitem__(8, replace(
            rows[8], domain="exact", def_id=74, canonical_key="effect_local"))),
        ("effect dict-only domain", lambda rows: rows.__setitem__(8, replace(
            rows[8], domain="static"))),
        ("empty NameOnly key", lambda rows: rows.__setitem__(6, replace(
            rows[6], canonical_key=""))),
        ("empty Static key", lambda rows: rows.__setitem__(10, replace(
            rows[10], canonical_key=""))),
        ("Static producer", lambda rows: rows.__setitem__(10, replace(
            rows[10], producer="forged"))),
        ("empty effect NameOnly key", lambda rows: rows.__setitem__(8, replace(
            rows[8], canonical_key=""))),
        ("empty Computed producer", lambda rows: rows.__setitem__(12, replace(
            rows[12], producer=""))),
        ("Computed key", lambda rows: rows.__setitem__(12, replace(
            rows[12], canonical_key="forged"))),
        ("empty Fresh producer", lambda rows: rows.__setitem__(4, replace(
            rows[4], producer=""))),
        ("Fresh key", lambda rows: rows.__setitem__(4, replace(
            rows[4], canonical_key="forged"))),
        ("Exact closure edge", lambda rows: rows.__setitem__(4, replace(
            rows[4], domain="exact", def_id=41, canonical_key="x",
            producer=""))),
        ("load orphan", lambda rows: rows.pop(7)),
        ("call orphan", lambda rows: rows.__setitem__(7, replace(
            rows[7], load_id=77))),
        ("load/call frame", lambda rows: rows.__setitem__(7, replace(
            rows[7], parent_frame="other_child"))),
        ("load/call producer", lambda rows: rows.__setitem__(7, replace(
            rows[7], producer="effect-receiver-load"))),
        ("loaded call non-receiver producer", lambda rows: rows.__setitem__(7,
            replace(rows[7], producer="expression-closure"))),
        ("slot call load id", lambda rows: rows.__setitem__(14, replace(
            rows[14], load_id=99))),
        ("zero-load receiver producer", lambda rows: rows.__setitem__(16,
            replace(rows[16], producer="dict-receiver-load"))),
        ("negative computed load", lambda rows: rows.__setitem__(16,
            replace(rows[16], load_id=-1))),
        ("Fresh closure call", lambda rows: rows.__setitem__(14, replace(
            rows[14], domain="fresh", def_id=-1, canonical_key="",
            producer="closure-edge:child_a"))),
        ("zero arity", lambda rows: rows.__setitem__(14, replace(
            rows[14], arity=0))),
        ("nondeterministic order", lambda rows: rows.__setitem__(slice(0, 2),
            [rows[1], rows[0]])),
    )
    for label, mutate in mutations:
        rows = list(events)
        mutate(rows)
        _, mutation_errors = parse_identity_ledger(
            serialize_identity_ledger(rows))
        if not mutation_errors:
            errors.append(f"identity ledger mutation escaped: {label}")
    return errors


def extract_c_switch_cases(
    function_body: str,
) -> Tuple[dict[str, str], Optional[str]]:
    """Extract top-level bodies from the sole switch in a generated function."""
    masked = mask_c_strings_and_comments(function_body)
    switches = list(re.finditer(r"\bswitch\s*\(", masked))
    if len(switches) != 1:
        return {}, f"expected one switch, found {len(switches)}"
    paren_open = masked.find("(", switches[0].start(), switches[0].end())
    try:
        paren_close = matching_delimiter(masked, paren_open, "(", ")")
    except ValueError as exc:
        return {}, str(exc)
    brace_open = paren_close + 1
    while brace_open < len(masked) and masked[brace_open].isspace():
        brace_open += 1
    if brace_open >= len(masked) or masked[brace_open] != "{":
        return {}, "switch has no braced body"
    try:
        brace_close = matching_delimiter(masked, brace_open, "{", "}")
    except ValueError as exc:
        return {}, str(exc)

    inner_masked = masked[brace_open + 1:brace_close]
    inner_source = function_body[brace_open + 1:brace_close]
    labels: List[Tuple[str, int, int]] = []
    depth = 0
    index = 0
    label_re = re.compile(r"(?:case\s+(-?[0-9]+)\s*|default\s*):")
    while index < len(inner_masked):
        char = inner_masked[index]
        if char == "{":
            depth += 1
            index += 1
            continue
        if char == "}":
            depth -= 1
            index += 1
            continue
        if depth == 0:
            match = label_re.match(inner_masked, index)
            if match:
                label = match.group(1) if match.group(1) is not None else "default"
                labels.append((label, match.start(), match.end()))
                index = match.end()
                continue
        index += 1

    if not labels:
        return {}, "switch contains no top-level case labels"
    cases: dict[str, str] = {}
    for label_index, (label, start, body_start) in enumerate(labels):
        if label in cases:
            return {}, f"duplicate switch label {label}"
        body_end = (
            labels[label_index + 1][1]
            if label_index + 1 < len(labels)
            else len(inner_source)
        )
        cases[label] = inner_source[body_start:body_end]
    return cases, None


def c_rc_counts(c_body: str) -> Tuple[int, int]:
    """Return exact (ring_dup, ring_drop) call counts in a local C body."""
    masked = mask_c_strings_and_comments(c_body)
    return (
        len(re.findall(r"\bring_dup\s*\(", masked)),
        len(re.findall(r"\bring_drop\s*\(", masked)),
    )


@dataclass(frozen=True)
class CProbeStatement:
    """One statement in the deliberately tiny generated-C probe grammar."""

    kind: str
    offset: int
    text: str
    target: Optional[str] = None
    callee: Optional[str] = None
    args: Tuple[str, ...] = ()


@dataclass(frozen=True)
class CProbeEvent:
    """A probe statement with identifier origins frozen at its execution point."""

    statement: CProbeStatement
    arg_origins: Tuple[str, ...] = ()
    result_origin: Optional[str] = None


@dataclass(frozen=True)
class CProbeProgram:
    """The sole evaluated truth consumed by the exact body template."""

    events: Tuple[CProbeEvent, ...]


C_PROBE_CALL_ARITIES = {
    "ring_list_new": 0,
    "ring_List_push": 2,
}
C_PROBE_VALUE_ROOT = "parameter:r_value"
C_PROBE_UNIT_ROOT = "constant:RING_UNIT"
# Intentionally lock the complete alpha-normalized lowering.  Independent
# semantic/RC summaries admitted use-after-drop reorderings in these probes.
C_PROBE_TEMPLATES = {
    "ring_structural_raw_identity": (
        ("declare", "v0"),
        ("declare", "v1"),
        ("declare", "v2"),
        ("alias", "v0", "$value"),
        ("alias", "v1", "v0"),
        ("alias", "v2", "v1"),
        ("return", "v2"),
    ),
    "ring_structural_owned_identity": (
        ("declare", "v0"),
        ("declare", "v1"),
        ("declare", "v2"),
        ("declare", "v3"),
        ("declare", "v4"),
        ("alias", "v0", "$value"),
        ("rc", "ring_dup", "v0"),
        ("alias", "v1", "v0"),
        ("alias", "v2", "v1"),
        ("rc", "ring_dup", "v2"),
        ("alias", "v3", "v2"),
        ("rc", "ring_drop", "v1"),
        ("alias", "v4", "v3"),
        ("return", "v4"),
    ),
    "ring_structural_raw_list": (
        ("declare", "v0"),
        ("declare", "v1"),
        ("declare", "v2"),
        ("declare", "v3"),
        ("declare", "v4"),
        ("call", "v0", "ring_list_new"),
        ("alias", "v1", "v0"),
        ("alias", "v2", "$value"),
        ("alias", "v3", "v1"),
        ("call", "v4", "ring_List_push", "v3", "v2"),
        ("return", "$unit"),
    ),
    "ring_structural_owned_list": (
        ("declare", "v0"),
        ("declare", "v1"),
        ("declare", "v2"),
        ("declare", "v3"),
        ("declare", "v4"),
        ("declare", "v5"),
        ("declare", "v6"),
        ("call", "v0", "ring_list_new"),
        ("alias", "v1", "v0"),
        ("alias", "v2", "$value"),
        ("alias", "v3", "v1"),
        ("call", "v4", "ring_List_push", "v3", "v2"),
        ("alias", "v5", "$unit"),
        ("rc", "ring_drop", "v1"),
        ("alias", "v6", "v5"),
        ("return", "v6"),
    ),
}


def c_probe_lexical_errors(symbol: str, c_body: str) -> List[str]:
    """Fail closed before applying the six probes' finite statement grammar."""
    errors: List[str] = []
    for marker, description in (
        ("//", "line comment"),
        ("/*", "block comment"),
        ("*/", "block-comment terminator"),
    ):
        if marker in c_body:
            errors.append(f"{symbol}: {description} is outside finite grammar")
    if '"' in c_body:
        errors.append(f"{symbol}: string literal is outside finite grammar")
    if "'" in c_body:
        errors.append(f"{symbol}: character literal is outside finite grammar")
    if re.search(r"\\\r?\n", c_body):
        errors.append(
            f"{symbol}: backslash-newline splice is outside finite grammar")
    if re.search(r"(?m)^[ \t]*#", c_body):
        errors.append(
            f"{symbol}: preprocessor directive is outside finite grammar")
    if "{" in c_body or "}" in c_body:
        errors.append(f"{symbol}: nested block is outside finite grammar")
    controls = sorted(set(re.findall(
        r"\b(?:goto|if|switch|for|while|do|break|continue|case|default)\b",
        c_body)))
    if controls:
        errors.append(
            f"{symbol}: control flow is outside finite grammar: "
            f"{', '.join(controls)}")
    return errors


def parse_c_probe_statements(
    symbol: str,
    c_body: str,
) -> Tuple[List[CProbeStatement], List[str]]:
    """Fully consume a body using only the accepted straight-line grammar."""
    errors = c_probe_lexical_errors(symbol, c_body)
    if errors:
        return [], errors

    ident = r"[A-Za-z_][A-Za-z0-9_]*"
    statements: List[CProbeStatement] = []
    cursor = 0
    for terminator in re.finditer(r";", c_body):
        segment = c_body[cursor:terminator.start()]
        leading = len(segment) - len(segment.lstrip())
        offset = cursor + leading
        text = segment.strip()
        cursor = terminator.end()
        if not text:
            errors.append(f"{symbol}: empty statement is outside finite grammar")
            continue

        declaration = re.fullmatch(
            rf"void\s*\*\s*({ident})(?:\s*=\s*NULL)?", text)
        if declaration:
            statements.append(CProbeStatement(
                "declare", offset, text, target=declaration.group(1)))
            continue

        assigned_call = re.fullmatch(
            rf"({ident})\s*=\s*({ident})\s*\(([^()]*)\)", text)
        if assigned_call:
            target, callee, args_text = assigned_call.groups()
            args = (
                tuple(arg.strip() for arg in args_text.split(","))
                if args_text.strip() else ())
            if callee not in C_PROBE_CALL_ARITIES:
                errors.append(
                    f"{symbol}: assigned call {callee} is outside finite grammar")
                continue
            if any(re.fullmatch(ident, arg) is None for arg in args):
                errors.append(
                    f"{symbol}: {callee} arguments are outside finite grammar")
                continue
            expected_arity = C_PROBE_CALL_ARITIES[callee]
            if len(args) != expected_arity:
                errors.append(
                    f"{symbol}: {callee} arity {len(args)} != "
                    f"{expected_arity}")
                continue
            statements.append(CProbeStatement(
                "call", offset, text, target=target, callee=callee,
                args=args))
            continue

        alias = re.fullmatch(rf"({ident})\s*=\s*({ident})", text)
        if alias:
            statements.append(CProbeStatement(
                "alias", offset, text, target=alias.group(1),
                args=(alias.group(2),)))
            continue

        standalone_call = re.fullmatch(
            rf"({ident})\s*\(([^()]*)\)", text)
        if standalone_call:
            callee, args_text = standalone_call.groups()
            args = (
                tuple(arg.strip() for arg in args_text.split(","))
                if args_text.strip() else ())
            if callee not in {"ring_dup", "ring_drop"}:
                errors.append(
                    f"{symbol}: standalone call {callee} is outside "
                    "finite grammar")
                continue
            if len(args) != 1 or re.fullmatch(ident, args[0]) is None:
                errors.append(
                    f"{symbol}: {callee} requires one identifier operand")
                continue
            statements.append(CProbeStatement(
                "rc", offset, text, callee=callee, args=args))
            continue

        returned = re.fullmatch(rf"return\s+({ident})", text)
        if returned:
            statements.append(CProbeStatement(
                "return", offset, text, args=(returned.group(1),)))
            continue

        errors.append(
            f"{symbol}: statement is outside finite grammar: {text[:100]!r}")

    if c_body[cursor:].strip():
        errors.append(
            f"{symbol}: unterminated text is outside finite grammar: "
            f"{c_body[cursor:].strip()[:100]!r}")
    if not statements and not errors:
        errors.append(f"{symbol}: finite grammar parsed no statements")
    return statements, errors


def evaluate_c_probe_statements(
    symbol: str,
    statements: List[CProbeStatement],
) -> Tuple[Optional[CProbeProgram], List[str]]:
    """Freeze every identifier's origin once, in source execution order."""
    errors: List[str] = []
    declared = set()
    assigned = set()
    origins = {
        "r_value": C_PROBE_VALUE_ROOT,
        "RING_UNIT": C_PROBE_UNIT_ROOT,
    }
    events: List[CProbeEvent] = []
    executable_seen = False

    def resolve(name: str, offset: int) -> str:
        if name in origins:
            return origins[name]
        if name in declared:
            errors.append(
                f"{symbol}: {name} used before initialization at offset "
                f"{offset}")
        else:
            errors.append(
                f"{symbol}: undeclared identifier {name} used at offset "
                f"{offset}")
        return f"invalid:{name}@{offset}"

    def assign(target: str, origin: str, offset: int) -> None:
        if target not in declared:
            errors.append(
                f"{symbol}: assignment target {target} was not declared at "
                f"offset {offset}")
        if target in assigned:
            errors.append(
                f"{symbol}: assignment target {target} assigned more than once")
            return
        assigned.add(target)
        origins[target] = origin

    for statement in statements:
        if statement.kind == "declare":
            target = statement.target or ""
            if executable_seen:
                errors.append(
                    f"{symbol}: declaration {target} follows executable code")
            if target in declared or target in origins:
                errors.append(f"{symbol}: duplicate declaration {target}")
            declared.add(target)
            events.append(CProbeEvent(statement))
            continue

        executable_seen = True
        arg_origins = tuple(
            resolve(arg, statement.offset) for arg in statement.args)
        if statement.kind == "alias":
            result_origin = arg_origins[0]
            assign(statement.target or "", result_origin, statement.offset)
            events.append(CProbeEvent(
                statement, arg_origins, result_origin))
        elif statement.kind == "call":
            result_origin = (
                f"call:{statement.offset}:{statement.callee}")
            assign(statement.target or "", result_origin, statement.offset)
            events.append(CProbeEvent(
                statement, arg_origins, result_origin))
        else:
            events.append(CProbeEvent(statement, arg_origins))

    return_events = [
        event for event in events if event.statement.kind == "return"]
    if len(return_events) != 1:
        errors.append(
            f"{symbol}: expected exactly one return event, found "
            f"{len(return_events)}")
    elif not events or events[-1].statement.kind != "return":
        errors.append(f"{symbol}: return event is not the final statement")

    if errors:
        return None, errors
    return CProbeProgram(tuple(events)), []


def canonical_c_probe_events(
    symbol: str,
    program: CProbeProgram,
) -> Tuple[Tuple[Tuple[str, ...], ...], List[str]]:
    """Alpha-normalize locals while preserving every statement and operand."""
    errors: List[str] = []
    locals_by_name: dict[str, str] = {}
    normalized: List[Tuple[str, ...]] = []

    def identifier(name: str, offset: int) -> str:
        if name == "r_value":
            return "$value"
        if name == "RING_UNIT":
            return "$unit"
        local = locals_by_name.get(name)
        if local is None:
            errors.append(
                f"{symbol}: cannot canonicalize identifier {name} at "
                f"offset {offset}")
            return f"$invalid:{name}"
        return local

    for event in program.events:
        statement = event.statement
        if statement.kind == "declare":
            target = statement.target or ""
            canonical = f"v{len(locals_by_name)}"
            if target in locals_by_name:
                errors.append(
                    f"{symbol}: cannot canonicalize duplicate local {target}")
            locals_by_name[target] = canonical
            normalized.append(("declare", canonical))
            continue

        target = (
            identifier(statement.target, statement.offset)
            if statement.target is not None else None)
        args = tuple(
            identifier(arg, statement.offset) for arg in statement.args)
        if statement.kind == "alias":
            normalized.append(("alias", target or "$invalid", *args))
        elif statement.kind == "call":
            normalized.append((
                "call", target or "$invalid", statement.callee or "", *args))
        elif statement.kind == "rc":
            normalized.append(("rc", statement.callee or "", *args))
        elif statement.kind == "return":
            normalized.append(("return", *args))
        else:
            errors.append(
                f"{symbol}: cannot canonicalize event kind {statement.kind}")
    return tuple(normalized), errors


def c_probe_template_errors(
    symbol: str,
    program: CProbeProgram,
) -> List[str]:
    """Match the complete alpha-normalized body, including exact ordering."""
    expected = C_PROBE_TEMPLATES.get(symbol)
    if expected is None:
        return [f"{symbol}: no canonical probe template"]
    actual, errors = canonical_c_probe_events(symbol, program)
    if errors:
        return errors
    if actual == expected:
        return []
    mismatch = next(
        (index for index, pair in enumerate(zip(actual, expected))
         if pair[0] != pair[1]),
        min(len(actual), len(expected)),
    )
    actual_event = actual[mismatch] if mismatch < len(actual) else "<end>"
    expected_event = (
        expected[mismatch] if mismatch < len(expected) else "<end>")
    return [
        f"{symbol}: normalized event template mismatch at {mismatch}: "
        f"{actual_event!r} != {expected_event!r} "
        f"(actual/expected events {len(actual)}/{len(expected)})"
    ]


def validate_c_probe_body(symbol: str, c_body: str) -> List[str]:
    """Parse, source-order evaluate, and template-check one probe body."""
    statements, parse_errors = parse_c_probe_statements(symbol, c_body)
    if parse_errors:
        return parse_errors
    program, evaluation_errors = evaluate_c_probe_statements(
        symbol, statements)
    if evaluation_errors:
        return evaluation_errors
    if program is None:
        return [f"{symbol}: finite-grammar evaluator produced no program"]
    return c_probe_template_errors(symbol, program)


C_PROBE_MUTATION_MATRIX = (
    (
        "identity-wrong-rc-roots",
        "ring_structural_owned_identity",
        """void* t1; void* r_local; void* t2; void* r_scope;
void* t3; void* r_decoy;
t1 = r_value; r_decoy = RING_UNIT; ring_dup(r_decoy);
r_local = t1; t2 = r_local; ring_dup(r_decoy); r_scope = t2;
ring_drop(r_decoy); t3 = r_scope; return t3;""",
        "normalized event template mismatch",
    ),
    (
        "list-wrong-drop-root",
        "ring_structural_owned_list",
        """void* t1; void* r_values; void* t2; void* t3; void* t4;
t1 = ring_list_new(); r_values = t1; t2 = r_value; t3 = r_values;
t4 = ring_List_push(t3, t2); ring_drop(r_value); return RING_UNIT;""",
        "normalized event template mismatch",
    ),
    (
        "list-use-after-drop",
        "ring_structural_owned_list",
        """void* t1; void* r_values; void* t2; void* t3; void* t4;
void* r_scope; void* t5;
t1 = ring_list_new(); r_values = t1; t2 = r_value; t3 = r_values;
ring_drop(r_values); t4 = ring_List_push(t3, t2);
r_scope = RING_UNIT; t5 = r_scope; return t5;""",
        "normalized event template mismatch",
    ),
    (
        "identity-wrong-return-root",
        "ring_structural_raw_identity",
        """void* t1; void* t2;
t1 = r_value; t2 = RING_UNIT; return t2;""",
        "normalized event template mismatch",
    ),
    (
        "list-wrong-push-receiver",
        "ring_structural_raw_list",
        """void* t1; void* r_values; void* t2; void* t3;
t1 = ring_list_new(); r_values = t1; t2 = r_value;
t3 = ring_List_push(t2, t2); return RING_UNIT;""",
        "normalized event template mismatch",
    ),
    (
        "list-missing-push",
        "ring_structural_raw_list",
        """void* t1; void* r_values;
t1 = ring_list_new(); r_values = t1; return RING_UNIT;""",
        "normalized event template mismatch",
    ),
    (
        "non-null-declaration-initializer",
        "ring_structural_raw_identity",
        """void* t1 = RING_UNIT; void* r_local; void* t2;
t1 = r_value; r_local = t1; t2 = r_local; return t2;""",
        "statement is outside finite grammar",
    ),
)


def c_probe_mutation_matrix_errors() -> List[str]:
    """Keep every accepted Argument counterexample permanently rejected."""
    errors: List[str] = []
    null_initialized_canonical = """void* t1 = NULL;
void* r_local = NULL; void* t2 = NULL;
t1 = r_value; r_local = t1; t2 = r_local; return t2;"""
    positive_errors = validate_c_probe_body(
        "ring_structural_raw_identity", null_initialized_canonical)
    if positive_errors:
        errors.append(
            "NULL-initialized canonical probe was rejected: "
            f"{' | '.join(positive_errors)}")
    for name, symbol, body, expected_fragment in C_PROBE_MUTATION_MATRIX:
        mutation_errors = validate_c_probe_body(symbol, body)
        if not mutation_errors:
            errors.append(f"mutation {name} was accepted")
            continue
        if not any(expected_fragment in error for error in mutation_errors):
            errors.append(
                f"mutation {name} missed {expected_fragment!r}: "
                f"{' | '.join(mutation_errors)}")
    return errors


def decode_c_path(encoded: str) -> str:
    """Decode the limited C escapes emitted in generated #line paths."""
    result: List[str] = []
    escapes = {
        "\\": "\\", '"': '"', "n": "\n", "r": "\r", "t": "\t",
    }
    index = 0
    while index < len(encoded):
        char = encoded[index]
        if char != "\\":
            result.append(char)
            index += 1
            continue
        if index + 1 >= len(encoded) or encoded[index + 1] not in escapes:
            raise ValueError(f"unsupported C escape in #line path: {encoded!r}")
        result.append(escapes[encoded[index + 1]])
        index += 2
    return "".join(result)


def parse_c_line_directives(
    c_source: str,
) -> Tuple[List[Tuple[int, int, str]], List[str]]:
    """Parse every directive-like line and require canonical column-0 syntax."""
    directives: List[Tuple[int, int, str]] = []
    errors: List[str] = []
    offset = 0
    for line_number, line in enumerate(c_source.splitlines(keepends=True), 1):
        text = line.rstrip("\r\n")
        if re.match(r"^[ \t]*#[ \t]*line\b", text):
            match = C_LINE_DIRECTIVE_RE.fullmatch(text)
            if not match:
                errors.append(
                    f"generated C line {line_number} has non-canonical #line: "
                    f"{text[:120]!r}")
            else:
                try:
                    path = decode_c_path(match.group("path"))
                except ValueError as exc:
                    errors.append(f"generated C line {line_number}: {exc}")
                else:
                    directives.append((offset, int(match.group("line")), path))
        offset += len(line)
    return directives, errors


def normalized_newline_bytes(path: Path) -> bytes:
    """Read bytes while normalizing only platform line endings."""
    return path.read_bytes().replace(b"\r\n", b"\n")


def without_c_line_directives(data: bytes) -> bytes:
    """Remove canonical column-0 #line records from normalized generated C."""
    return b"".join(
        line for line in data.splitlines(keepends=True)
        if not line.startswith(b"#line ")
    )


def build_c_artifacts_fresh(
    ring_exe: str,
    entry_text: str,
    temp_root: Path,
    *,
    no_c_lines: bool,
    phase_case: Optional[str] = None,
) -> Tuple[Optional[Path], Optional[Path], Optional[str]]:
    """Build into a newly-created empty dir and require fresh .c/.o outputs."""
    mode = "off" if no_c_lines else "default"
    out_dir = Path(tempfile.mkdtemp(prefix=f"{mode}_", dir=str(temp_root)))
    if any(out_dir.iterdir()):
        return None, None, f"fresh output directory was not empty: {out_dir}"
    entry = (REPO / entry_text).resolve()
    extra_args = ["--no-c-lines"] if no_c_lines else None
    try:
        result = ring_build(
            ring_exe, str(entry), out_dir=str(out_dir),
            extra_args=extra_args, phase_suite="structural",
            phase_case=phase_case)
    except subprocess.TimeoutExpired:
        return None, None, f"{mode} C build timed out for {entry_text}"
    if result.returncode != 0:
        output = norm(result.stderr or result.stdout or "")[:500]
        return None, None, (
            f"{mode} C build failed (exit {result.returncode}) for "
            f"{entry_text}: {output}")

    expected_c = out_dir / f"{entry.stem}.c"
    expected_o = out_dir / f"{entry.stem}.o"
    actual_c = sorted(path.resolve() for path in out_dir.rglob("*.c"))
    actual_o = sorted(path.resolve() for path in out_dir.rglob("*.o"))
    if actual_c != [expected_c.resolve()] or actual_o != [expected_o.resolve()]:
        return None, None, (
            f"{mode} C build emitted unexpected artifacts for {entry_text}: "
            f".c={len(actual_c)}, .o={len(actual_o)}")
    if expected_c.stat().st_size == 0 or expected_o.stat().st_size == 0:
        return None, None, f"{mode} C build emitted an empty artifact for {entry_text}"
    return expected_c, expected_o, None


def validate_line_directive_pair(
    default_c: Path,
    off_c: Path,
    marker_path: Path,
    marker_id: str,
    marker_line: int,
) -> List[str]:
    """Validate mapping, global disablement, and byte-equivalence modulo lines."""
    errors: List[str] = []
    try:
        default_bytes = normalized_newline_bytes(default_c)
        off_bytes = normalized_newline_bytes(off_c)
        default_source = default_bytes.decode("utf-8")
        off_source = off_bytes.decode("utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read generated C: {exc}"]

    directives, parse_errors = parse_c_line_directives(default_source)
    errors.extend(parse_errors)
    if not directives:
        errors.append("default generated C contains no canonical #line directives")

    # Every non-synthetic directive must name an absolute, existing source and
    # a line inside that source. The marker below proves exact statement-level
    # mapping, rather than accepting a merely in-range number.
    source_line_counts: dict[str, int] = {}
    for _, line, path_text in directives:
        if path_text == "<perceus>":
            if line != 0:
                errors.append(f"synthetic <perceus> directive uses line {line}")
            continue
        source_path = Path(path_text)
        if not source_path.is_absolute():
            errors.append(f"#line path is not absolute: {path_text}")
            continue
        if path_text not in source_line_counts:
            try:
                source_line_counts[path_text] = len(
                    source_path.read_text(encoding="utf-8").splitlines())
            except (OSError, UnicodeError) as exc:
                errors.append(f"#line source cannot be read: {path_text}: {exc}")
                continue
        if line < 1 or line > source_line_counts[path_text]:
            errors.append(
                f"#line {line} is outside source {path_text} "
                f"(1..{source_line_counts[path_text]})")

    off_directives, off_parse_errors = parse_c_line_directives(off_source)
    errors.extend(off_parse_errors)
    if off_directives or re.search(r"(?m)^[ \t]*#[ \t]*line\b", off_source):
        errors.append("--no-c-lines generated C still contains a #line directive")

    masked_c = mask_c_strings_and_comments(default_source)
    assignment_re = re.compile(
        rf"(?m)^[ \t]*r_{re.escape(marker_id)}[ \t]*=")
    assignments = list(assignment_re.finditer(masked_c))
    if len(assignments) != 1:
        errors.append(
            f"generated marker assignment r_{marker_id} found "
            f"{len(assignments)} times")
    else:
        prior = [directive for directive in directives
                 if directive[0] < assignments[0].start()]
        if not prior:
            errors.append(f"marker {marker_id} has no preceding #line directive")
        else:
            _, actual_line, actual_path = prior[-1]
            expected_path = str(marker_path.resolve())
            if actual_line != marker_line or actual_path != expected_path:
                errors.append(
                    f"marker {marker_id} maps to {actual_path}:{actual_line}, "
                    f"expected {expected_path}:{marker_line}")

    if without_c_line_directives(default_bytes) != off_bytes:
        errors.append(
            "default generated C after removing #line records differs from "
            "--no-c-lines output")
    return errors


def run_c_line_oracle(
    ring_exe: str,
    temp_root: Path,
    entry: str,
    fixtures: Tuple[str, ...],
    phase_case: Optional[str] = None,
) -> List[str]:
    """Build one line-directive fixture in both modes and compare artifacts."""
    markers: List[Tuple[Path, str, int]] = []
    for fixture in fixtures:
        path = REPO / fixture
        found, error = ring_line_markers(path)
        if error:
            return [error]
        markers.extend((path, marker_id, line) for marker_id, line in found)
    if len(markers) != 1:
        return [f"{entry}: expected one real-code marker, found {len(markers)}"]

    default_c, _, error = build_c_artifacts_fresh(
        ring_exe, entry, temp_root, no_c_lines=False,
        phase_case=phase_case)
    if error:
        return [error]
    off_c, _, error = build_c_artifacts_fresh(
        ring_exe, entry, temp_root, no_c_lines=True,
        phase_case=phase_case)
    if error:
        return [error]
    marker_path, marker_id, marker_line = markers[0]
    return validate_line_directive_pair(
        default_c, off_c, marker_path, marker_id, marker_line)


def exact_rc_error(symbol: str, body: str,
                   expected: Tuple[int, int]) -> Optional[str]:
    actual = c_rc_counts(body)
    if actual != expected:
        return (
            f"{symbol}: expected ring_dup/ring_drop {expected[0]}/{expected[1]}, "
            f"found {actual[0]}/{actual[1]}")
    return None


def run_extern_rc_oracle(ring_exe: str, temp_root: Path,
                         phase_case: Optional[str] = None) -> List[str]:
    """Inspect local generated-C bodies without executing any raw handle."""
    errors = c_probe_mutation_matrix_errors()
    c_path, _, error = build_c_artifacts_fresh(
        ring_exe, EXTERN_RC_FIXTURE, temp_root, no_c_lines=True,
        phase_case=phase_case)
    if error:
        return [error]
    try:
        c_source = c_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read generated extern-handle C: {exc}"]
    if re.search(r"(?m)^[ \t]*#[ \t]*line\b", c_source):
        errors.append("extern-handle --no-c-lines artifact contains #line")

    function_expectations = {
        **{symbol: None for symbol in C_PROBE_TEMPLATES},
        "ring_drop_StructuralHolder": (0, 1),
    }
    bodies: dict[str, str] = {}
    for symbol, expected in function_expectations.items():
        body, extract_error = extract_c_function_body(c_source, symbol)
        if extract_error:
            errors.append(extract_error)
            continue
        bodies[symbol] = body
        if expected is not None:
            count_error = exact_rc_error(symbol, body, expected)
            if count_error:
                errors.append(count_error)
        if symbol in C_PROBE_TEMPLATES:
            errors.extend(validate_c_probe_body(symbol, body))

    holder_body = bodies.get("ring_drop_StructuralHolder")
    if holder_body is not None:
        masked_holder = mask_c_strings_and_comments(holder_body)
        holder_slots = re.findall(
            r"\bring_drop\s*\(\s*\(\(void\s*\*\s*\*\)p\)"
            r"\s*\[\s*([0-9]+)\s*\]\s*\)",
            masked_holder,
        )
        if holder_slots != ["1"]:
            errors.append(
                "ring_drop_StructuralHolder must drop exactly owned slot 1; "
                f"found slots {holder_slots}")

    choice_body, extract_error = extract_c_function_body(
        c_source, "ring_drop_StructuralChoice")
    if extract_error:
        errors.append(extract_error)
    else:
        count_error = exact_rc_error(
            "ring_drop_StructuralChoice", choice_body, (0, 1))
        if count_error:
            errors.append(count_error)
        cases, case_error = extract_c_switch_cases(choice_body)
        if case_error:
            errors.append(f"ring_drop_StructuralChoice: {case_error}")
        elif set(cases) != {"0", "1", "default"}:
            errors.append(
                "ring_drop_StructuralChoice labels differ from "
                f"0/1/default: {sorted(cases)}")
        else:
            for label, expected in (("0", (0, 0)), ("1", (0, 1)),
                                    ("default", (0, 0))):
                count_error = exact_rc_error(
                    f"ring_drop_StructuralChoice case {label}",
                    cases[label], expected)
                if count_error:
                    errors.append(count_error)
            masked_owned = mask_c_strings_and_comments(cases["1"])
            owned_slots = re.findall(
                r"\bring_drop\s*\(\s*\(\(void\s*\*\s*\*\)p\)"
                r"\s*\[\s*([0-9]+)\s*\]\s*\)",
                masked_owned,
            )
            if owned_slots != ["1"]:
                errors.append(
                    "StructuralChoice::Owned must drop exactly payload slot 1; "
                    f"found slots {owned_slots}")

    return errors


def identity_ledger_contract_errors(
    sources: dict[str, str],
) -> List[str]:
    """Lock H+T typed authority, atomic emitters, and hidden output boundary."""
    errors: List[str] = []
    cctx = sources["cctx"]
    cexpr = sources["cexpr"]
    cgen = sources["cgen"]
    cli = sources["cli"]

    inventory = (
        ("closure-call", cexpr.count("gen_c_closure_call(")
         + cgen.count("gen_c_closure_call("), 10),
        ("dict-ref", cexpr.count("c_resolve_dict_ref(")
         + cgen.count("c_resolve_dict_ref("), 15),
        ("evidence", cexpr.count("c_lookup_evidence("), 6),
    )
    for label, actual, expected in inventory:
        if actual != expected:
            errors.append(
                f"H+T {label} frozen inventory {actual} != {expected}")

    typed_tokens = (
        "pub struct CExactSlotRef",
        "pub struct CNameOnlySlotRef",
        "pub enum CRefKind",
        "pub struct CTypedRef",
        "Map<Int, CExactSlotRef>",
        "Map<Str, CNameOnlySlotRef>",
        "pub fn c_ref_loaded(",
        "fn validate_identity_domain_shape(",
        "fn validate_c_typed_ref(",
        "fn validate_identity_event_shape(",
        "pub fn c_identity_ledger_text(",
        "validate_identity_ledger(ctx)",
    )
    for token in typed_tokens:
        if token not in cctx:
            errors.append(f"H+T typed authority missing {token!r}")
    for label in ("cexpr", "cgen"):
        if "CRefKind::" in sources[label] or re.search(
                r"CTypedRef\s*\{\s*c_name\s*:", sources[label]):
            errors.append(f"{label}: caller forged a typed ref variant/struct")
    if not re.search(
            r"pub fn gen_c_closure_call\s*\(\s*mut ctx: CCtx,\s*"
            r"closure_ref: CTypedRef,", cexpr):
        errors.append("gen_c_closure_call regained an untyped/raw overload")

    domain_shape_body, domain_shape_error = extract_ring_function_body(
        cctx, "validate_identity_domain_shape")
    if domain_shape_error:
        errors.append(domain_shape_error)
    else:
        for token in (
            'def_id == -1 || canonical_key == "" || producer != ""',
            'def_id != -1 || canonical_key == "" || producer != ""',
            'def_id != -1 || canonical_key != "" || producer == ""',
        ):
            if token not in domain_shape_body:
                errors.append(
                    f"validate_identity_domain_shape: missing {token!r}")
    typed_ref_body, typed_ref_error = extract_ring_function_body(
        cctx, "validate_c_typed_ref")
    if typed_ref_error:
        errors.append(typed_ref_error)
    else:
        for token in (
            'reference.c_name == "" || reference.load_id < 0',
            'validate_identity_domain_shape("exact", def_id, source_name, "")',
            'validate_identity_domain_shape("name-only", -1, canonical_key, "")',
            'validate_identity_domain_shape("static", -1, canonical_key, "")',
            'validate_identity_domain_shape("computed", -1, "", producer)',
            'validate_identity_domain_shape("fresh", -1, "", producer)',
        ):
            if token not in typed_ref_body:
                errors.append(f"validate_c_typed_ref: missing {token!r}")

    atomic_helpers = {
        "emit_c_capture_extract": (
            'c_emit(ctx, "${dest_name} = ((void**)env)[${index}];")',
            "c_record_capture_extract(\n        ctx, edge, dest, \"env\", dest_name, index)",
        ),
        "emit_c_capture_store": (
            'c_emit(ctx, "((void**)${env_name})[${index}] = ${source_name};")',
            "c_record_capture_store(\n        ctx, edge, identity, source_name, env_name, index)",
        ),
        "emit_c_closure_construction": (
            'c_emit(ctx, "((void**)${cls})[0] = (void*)${lambda_name};")',
            "c_record_closure_edge(",
        ),
        "emit_c_receiver_load": (
            'c_emit(ctx, "${dest} = ((void**)${source_name})[${index}];")',
            "c_record_receiver_load(",
            "c_ref_loaded(",
        ),
        "gen_c_closure_call": (
            'c_emit(ctx, "${t} = ((void* (*)(',
            "c_record_closure_call(\n        ctx, closure_ref, closure_val, t, arg_vals.len() + 1)",
        ),
    }
    for function_name, tokens in atomic_helpers.items():
        body, extract_error = extract_ring_function_body(cexpr, function_name)
        if extract_error:
            errors.append(extract_error)
            continue
        for token in tokens:
            if body.count(token) != 1:
                errors.append(
                    f"{function_name}: atomic C/event token {token!r} "
                    f"matched {body.count(token)} times")

    receiver_body, receiver_error = extract_ring_function_body(
        cexpr, "emit_c_receiver_load")
    if receiver_error:
        errors.append(receiver_error)
    else:
        for token in (
            'domain != "name-only" && domain != "static" && domain != "computed"',
            'domain != "name-only" && domain != "computed"',
            'domain != "computed"',
            "dict receiver has forbidden '${domain}' identity domain",
            "effect receiver has forbidden '${domain}' identity domain",
        ):
            if token not in receiver_body:
                errors.append(
                    f"emit_c_receiver_load: role/domain guard missing {token!r}")
        domain_anchor = "let domain = c_ref_domain(receiver)"
        emit_anchor = 'c_emit(ctx, "${dest} = ((void**)${source_name})[${index}];")'
        if domain_anchor in receiver_body and emit_anchor in receiver_body and (
                receiver_body.index(domain_anchor) > receiver_body.index(emit_anchor)):
            errors.append("receiver role/domain validation occurs after C emission")

    shape_body, shape_error = extract_ring_function_body(
        cctx, "validate_identity_event_shape")
    if shape_error:
        errors.append(shape_error)
    else:
        for token in (
            "validate_identity_domain_shape(",
            'event.domain != "fresh"',
            'event.producer != "closure-edge:${event.child_frame}"',
            'event.domain != "exact" && event.domain != "name-only"',
            'event.domain != "name-only" && event.domain != "static" &&',
            'event.domain != "name-only" &&\n'
            '           event.domain != "computed"',
            'event.domain != "computed"',
            'event.kind == "closure-call"',
            'event.load_id != 0',
            'event.load_id > 0',
            'event.load_id < 0 || receiver_load',
        ):
            if token not in shape_body:
                errors.append(
                    f"validate_identity_event_shape: missing {token!r}")

    relation_body, relation_error = extract_ring_function_body(
        cctx, "validate_identity_ledger")
    if relation_error:
        errors.append(relation_error)
    else:
        for token in (
            "validate_identity_event_shape(event)",
            "store.dest_slot != edge.source_slot",
            "store.parent_frame != edge.parent_frame",
            "store.child_frame != edge.child_frame",
            "extract.parent_frame != edge.parent_frame",
            "extract.child_frame != edge.child_frame",
            "event.parent_frame != load.parent_frame",
            "event.producer != load.kind",
        ):
            if token not in relation_body:
                errors.append(
                    f"validate_identity_ledger: relation guard missing {token!r}")
        if re.search(
            r"(?m)^        validate_identity_event_shape\(event\)$",
            relation_body,
        ) is None:
            errors.append("ledger loop does not execute event-shape authority")
    if cctx.count("validate_c_typed_ref(CTypedRef {") != 7:
        errors.append("all seven typed-reference constructors must validate shape")
    for token in (
        "exact local has an empty source name",
        "exact local '${ring_name}' has sentinel DefId",
        "name-only local has an empty canonical key",
        "exact parameter has an empty source name",
        "exact parameter '${ring_name}' has sentinel DefId",
        "name-only parameter has an empty canonical key",
        "name-only registration has an empty key/slot",
        "typed reference has an empty slot/invalid load id",
    ):
        if token not in cctx:
            errors.append(f"typed-reference constructor guard missing {token!r}")
    if cctx.count("identity_owned_slot_key(") != 5:
        errors.append(
            "identity ledger must derive exactly four frame-qualified slot uses")
    if '"${frame.len()}:${frame}:${slot}"' not in cctx:
        errors.append("identity ledger owned-slot key lost its frame component")

    record_calls = (
        ("c_record_capture_extract(", "emit_c_capture_extract"),
        ("c_record_capture_store(", "emit_c_capture_store"),
        ("c_record_closure_edge(", "emit_c_closure_construction"),
        ("c_record_receiver_load(", "emit_c_receiver_load"),
        ("c_record_closure_call(", "gen_c_closure_call"),
    )
    for token, owner in record_calls:
        if cexpr.count(token) != 1:
            errors.append(
                f"H+T event {token!r} has caller-created/bypassed count "
                f"{cexpr.count(token)}")
        owner_body, owner_error = extract_ring_function_body(cexpr, owner)
        if owner_error is None and token not in owner_body:
            errors.append(f"H+T event {token!r} is not owned by {owner}")
        if token in cgen or token in cli:
            errors.append(f"H+T event {token!r} escaped its atomic expr helper")

    for typed_map, expected_count in (
        ("Map<Int, CExactSlotRef>", 2),
        ("Map<Str, CNameOnlySlotRef>", 2),
    ):
        if cctx.count(typed_map) != expected_count:
            errors.append(
                f"H+T typed map {typed_map!r} count "
                f"{cctx.count(typed_map)} != {expected_count}")
    if re.search(
            r"emit_c_receiver_load\s*\([^)]*,\s*0\s*,\s*\"(?:dict|effect)\"",
            cexpr, re.DOTALL):
        errors.append("H+T receiver load regained a zero/non-method slot")

    raw_templates = (
        ('${dest_name} = ((void**)env)[${index}]', "emit_c_capture_extract"),
        ('((void**)${env_name})[${index}] = ${source_name}', "emit_c_capture_store"),
        ('((void**)${source_name})[${index}]', "emit_c_receiver_load"),
        ('((void**)${closure_val})[0]', "gen_c_closure_call"),
    )
    for token, owner in raw_templates:
        if cexpr.count(token) != 1:
            errors.append(
                f"H+T raw critical template {token!r} bypass count "
                f"{cexpr.count(token)} (owner {owner})")

    # Computed wrapper thunks forward env slots inline but never carry source
    # Exact/NameOnly identity. Freeze these three named exclusions so they
    # cannot silently migrate into the source-identity route.
    wrapper_env_token = 'fwd_args.push("((void**)env)['
    if cexpr.count(wrapper_env_token) != 3:
        errors.append(
            "H+T computed wrapper env exclusion inventory must remain 3")
    for function_name, expected in (
        ("gen_c_dict_closure_wrapper", 1),
        ("ensure_c_wrapped_method_thunk", 2),
    ):
        body, extract_error = extract_ring_function_body(cexpr, function_name)
        if extract_error:
            errors.append(extract_error)
        elif body.count(wrapper_env_token) != expected:
            errors.append(
                f"{function_name}: computed env exclusion count drifted")
        elif "c_record_capture_" in body:
            errors.append(
                f"{function_name}: computed wrapper entered source capture ledger")

    if cli.count('arg == "--internal-c-identity-ledger"') != 1:
        errors.append("hidden ledger flag is not one exact boolean parser arm")
    if "--internal-c-identity-ledger=" in cli:
        errors.append("hidden ledger flag regained a value/path form")
    usage_body, usage_error = extract_ring_function_body(cli, "usage")
    if usage_error:
        errors.append(usage_error)
    elif "internal-c-identity-ledger" in usage_body:
        errors.append("internal ledger flag leaked into public usage")
    if cli.count("--internal-c-identity-ledger is single-file only") != 1:
        errors.append("project/multifile ledger rejection drifted")
    if cgen.count('"${c_path}.identity-ledger"') != 1:
        errors.append("ledger output path is not one derived fixed path")
    if cgen.count("write_file(\n            \"${c_path}.identity-ledger\"") != 1:
        errors.append("ledger output is not written exactly once")
    relation_anchor = "some(c_identity_ledger_text(ctx))"
    write_anchor = '"${c_path}.identity-ledger"'
    if relation_anchor not in cgen or write_anchor not in cgen:
        errors.append("ledger relation/write boundary missing")
    elif cgen.index(relation_anchor) > cgen.index(write_anchor):
        errors.append("ledger write can precede relation validation")
    write_body, write_error = extract_ring_function_body(
        cgen, "c_write_and_compile")
    if write_error:
        errors.append(write_error)
    elif "file_exists" in write_body:
        errors.append("ledger output regained a check-then-write TOCTOU")

    runner = sources.get("runner", "")
    candidate_mode_match = re.search(
        r"(?ms)^def run_identity_candidate_mode\(.*?"
        r"(?=^def default_body_identity_generated_c_errors\()",
        runner,
    )
    if candidate_mode_match is None:
        errors.append("cannot isolate run_identity_candidate_mode source")
    else:
        candidate_mode_source = candidate_mode_match.group(0)
        for token in (
            "environment = dict(os.environ)",
            "environment.pop(IDENTITY_CANDIDATE_ENV, None)",
            "environment.pop(IDENTITY_EVIDENCE_ROOT_ENV, None)",
        ):
            if candidate_mode_source.count(token) != 1:
                errors.append(
                    f"run_identity_candidate_mode env authority missing {token!r}")
        if "_controlled_environment" in candidate_mode_source:
            errors.append(
                "run_identity_candidate_mode rebuilt a controlled nested environment")
    coff_helper_match = re.search(
        r"(?ms)^def coff_object_timestamp_equality_errors\(.*?"
        r"(?=^def default_body_identity_generated_c_errors\()",
        runner,
    )
    if coff_helper_match is None:
        errors.append("cannot isolate COFF object equality helper")
    else:
        coff_helper_source = coff_helper_match.group(0)
        for token in (
            "if len(data) < 20:",
            "if machine != 0x8664:",
            "if not 1 <= section_count <= 96:",
            "allowed_offsets = {4, 5, 6, 7}",
            "if not diff_offsets.issubset(allowed_offsets):",
            "normalized_left[4:8] =",
            "normalized_right[4:8] =",
        ):
            if coff_helper_source.count(token) != 1:
                errors.append(f"COFF timestamp equality authority missing {token!r}")
    generated_gate_match = re.search(
        r"(?ms)^def default_body_identity_generated_c_errors\(.*?"
        r"(?=^def identity_checkpoint_source_errors\()",
        runner,
    )
    if generated_gate_match is None:
        errors.append("cannot isolate generated-C identity gate")
    else:
        generated_gate_source = generated_gate_match.group(0)
        if generated_gate_source.count(
            "coff_object_timestamp_equality_errors("
        ) != 2:
            errors.append("generated-C gate does not compare both objects via COFF helper")
        for forbidden in (
            '("off/on1 object", off.object_bytes, on1.object_bytes)',
            '("on1/on2 object", on1.object_bytes, on2.object_bytes)',
        ):
            if forbidden in generated_gate_source:
                errors.append("generated-C gate restored raw object inequality")
    runner_tokens = (
        "OneShotSpec(",
        "run_one_shot(spec, result_validator=validate_artifacts)",
        "reviewed_argv=tuple(argv)",
        "reviewed_env=tuple(sorted(environment.items()))",
        "if list(out_dir.iterdir())",
        "if ledger_path.exists()",
        "create_one_shot_archive(case_root, archive_path)",
        "canonicalize_identity_stdout_root(",
        'IDENTITY_EVIDENCE_ROOT_ENV = "RING_IDENTITY_EVIDENCE_ROOT"',
        "evidence_root, evidence_error = identity_checkpoint_evidence_root()",
        "default_body_identity_generated_c_errors(\n            candidate, evidence_root, evidence_log)",
        "audit_one_shot_attempt(evidence_dir)",
        "archive_sha256",
        "def identity_ledger_event_shape_errors(",
        "errors.extend(identity_ledger_event_shape_errors(event))",
    )
    for token in runner_tokens:
        if token not in runner:
            errors.append(f"H+T runner contract missing {token!r}")
    if re.search(
        r"(?m)^        errors\.extend\("
        r"identity_ledger_event_shape_errors\(event\)\)$",
        runner,
    ) is None:
        errors.append("Python ledger relation bypasses event-shape authority")
    evidence_anchor = (
        "evidence_root, evidence_error = identity_checkpoint_evidence_root()")
    candidate_anchor = "errors.extend(default_body_identity_generated_c_errors("
    if evidence_anchor in runner and candidate_anchor in runner and (
            runner.index(evidence_anchor) > runner.index(candidate_anchor)):
        errors.append("candidate command can precede evidence-root authority")
    if re.search(
        r"(?m)^    evidence_root, evidence_error = "
        r"identity_checkpoint_evidence_root\(\)\n"
        r"    if evidence_error is not None:$",
        runner,
    ) is None:
        errors.append("identity checkpoint lacks executable evidence-root guard")
    if re.search(
        r"(?m)^    errors = identity_checkpoint_source_errors\(\)\n"
        r"    if errors:\n"
        r"        return errors, "
        r'"source/mutation authority failed; candidate not evaluated"$',
        runner,
    ) is None:
        errors.append("identity checkpoint source authority is not fail-first")
    if re.search(
        r"(?m)^        create_one_shot_archive\(case_root, archive_path\)\n"
        r"        archive_sha256 = _sha256_file\(archive_path\)$",
        runner,
    ) is None:
        errors.append("identity candidate lacks executable exclusive archive path")
    for rejected in (
        "TemporaryDirectory" + '(prefix="ring_identity_ledger_"',
        "TemporaryDirectory" + '(prefix="ring_identity_rc_"',
    ):
        if rejected in runner:
            errors.append("identity candidate evidence regained auto-cleanup root")

    provenance_contract = sources.get("provenance_contract", "")
    for rejected in (
        "parse_c_function_provenance_facts",
        "analyze_two_level_provenance_c",
        "_parse_uniform_closure_call_statement",
        "valid_two_level_c",
    ):
        for source_label, source in (
            ("runner", runner), ("provenance contract", provenance_contract),
        ):
            if re.search(
                rf"(?m)^def\s+{re.escape(rejected)}\s*\(", source
            ):
                errors.append(
                    f"rejected F parser remains active in {source_label}: "
                    f"{rejected}")

    h_t_functions = (
        ("cctx", "c_ref_domain"),
        ("cctx", "c_ref_def_id"),
        ("cctx", "c_ref_key"),
        ("cctx", "c_ref_producer"),
        ("cctx", "validate_identity_domain_shape"),
        ("cctx", "validate_c_typed_ref"),
        ("cctx", "validate_identity_event_shape"),
        ("cctx", "validate_identity_ledger"),
        ("cctx", "c_identity_ledger_text"),
        ("cexpr", "emit_c_capture_extract"),
        ("cexpr", "emit_c_capture_store"),
        ("cexpr", "emit_c_closure_construction"),
        ("cexpr", "emit_c_receiver_load"),
        ("cexpr", "gen_c_closure_call"),
    )
    payload_or_pattern = re.compile(
        r"(?m)^\s*[A-Za-z_][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*\s*"
        r"(?:\{(?!\s*\.\.\s*\})[^{}\n]+\}|"
        r"\(\s*(?!\s*\))[^()\n]+\))\s*\|(?!\|)")
    for source_name, function_name in h_t_functions:
        body, extract_error = extract_ring_function_body(
            sources[source_name], function_name)
        if extract_error:
            errors.append(extract_error)
            continue
        if payload_or_pattern.search(mask_ring_strings_and_comments(body)):
            errors.append(
                f"{source_name}.{function_name}: payload-binding OrPattern "
                "breaks tracked-gen0 crossing")
        if function_name in ("validate_identity_ledger", "c_identity_ledger_text") and (
                ".sort" in body or "sort_by" in body):
            errors.append(
                f"{source_name}.{function_name}: ledger order was sorted/reordered")
    return errors


def identity_checkpoint_contract_errors(
    sources: dict[str, str],
) -> List[str]:
    """Lock the behavior-preserving I-prime exact-slot transport."""
    errors: List[str] = []
    errors.extend(identity_ledger_contract_errors(sources))
    required_tokens = {
        "identity": (
            "pub const BUILTIN_VALUE_SITE_COUNT: Int = 10",
            "pub const BUILTIN_VALUE_HASH_COMBINE: Int = 5",
            "pub struct BuiltinValueSite",
            "pub fn builtin_value_symbol(",
            '"builtin-value:${tag.to_str()}"',
            '"builtin:value-site:${tag.to_str()}"',
        ),
        "builtins": (
            "pub struct CheckerBuiltinValue",
            "pub fn checker_only_builtin_values(",
            "pub fn checker_builtin_value_name(",
            "pub fn checker_builtin_value_symbol(",
            "BUILTIN_VALUE_CELL_CONSTRUCTOR",
            "BUILTIN_VALUE_ALLOC", "BUILTIN_VALUE_DEALLOC",
            "BUILTIN_VALUE_PTR_COPY", "BUILTIN_VALUE_PTR_FROM_ADDR",
            "builtin_value_symbol(site)",
        ),
        "hir": (
            "pub struct HPatternBinding",
            "Drop { name: Str, def_id: Int, slot: SlotRef, site: HResourceSite,",
            "reason: HResourceReason, ty: Type, span: Span }",
            "Take { source: HExpr, source_slot: SlotRef, saved_slot: SlotRef?,",
            "pub struct HResourceSite",
            "pub struct HResourceReason",
            "executable_ref: ExecutableRef",
            "impl_method_ref: ImplMethodRef?",
            "SYNTHETIC_DICT_DEF_ID_BASE",
            "SYNTHETIC_ANF_DEF_ID_BASE",
            "SYNTHETIC_RC_DEF_ID_BASE",
            "pub fn is_synthetic_dict_def_id(",
            "pub fn validate_hir_binder_def_ids",
            "fn validate_hir_local_reference(",
            "block_local_init(stmts, id)",
            "pub fn is_exact_direct_call_ident(",
            "def_id: some(_), dict_closure_dicts: some(_)",
            "BoundMethodValue { method: TraitMethodRef, evidence: DictRef }",
            "pub fn method_call_ref_bound_evidence(",
            "callee_ref: CalleeRef?",
            "system_host: SystemHostCallableRef?",
            "Call { base_dict: DictRef, extra_dicts: List<DictRef> }",
        ),
        "infer": (
            "fn infer_scoped_block(",
            "fn exact_pattern_bindings(",
            "fn exact_call_callee_ref(",
            "fn exact_system_host_callable(",
            "make_system_host_callable_ref(",
            "system_effects.get(0).unwrap(),\n"
            "        make_named_executable_ref(callee_ref_named_symbol(callee_ref))",
            "value_symbol_ref(ctx, def_id)",
            "current_identity_file_key(ctx)",
            "slot_domain_lexical(), def_id",
            "bindings: pattern_bindings",
            "resume_binding: resume_binding",
            "bound_evidence = some(DictRef::Simple(",
        ),
        "infer_decl": (
            "trait default parameter has no exact DefId",
            "params: op_params, return_type: op.return_type",
            "def_id: some(trait_param_def_id)",
            "def_id: some(exact_trait_def_id)",
            "DictRef::Static(dict_name), tm.ty",
            "let fn_def_id = match registration_scheme {",
        ),
        "checker": (
            "for builtin in checker_only_builtin_values()",
            "checker_builtin_value_symbol(builtin)",
            "record_value_symbol_ref(",
            "let has_errors = ctx.sink.has_errors()",
            "if !has_errors && assembled.drop_types.len() > 0",
            "let checked_program = if has_errors {",
            "program: checked_program",
        ),
        "infer_ctx": (
            "pub value_symbols: Map<Int, SymbolRef>",
            "value_symbols_by_payload: Map<Str, SymbolRef>",
            "for binding in plan.bindings {\n        match binding.namespace {",
            "NamespaceKind::Value",
            "symbol_ref_canonical_payload(binding.symbol)",
            "pub fn value_symbol_ref(",
            "system_effect_console()",
            "system_effect_fs()",
            "system_effect_process()",
            "struct OrPatternBindingAuthority",
            "fn collect_or_pattern_binding_names(",
            "fn same_or_pattern_binding_names(",
            "fn report_duplicate_or_pattern_bindings(",
            "Or-pattern alternatives must bind the same variables",
            "Pattern repeats binding '${duplicate}'",
            "Or-pattern must contain at least one alternative",
            "authority.scheme.ty, candidate.ty",
            "ctx.env.bind(authority.name, authority.scheme)",
            "canonical or-pattern binding has no exact DefId",
            "or-pattern alternative binding has no exact DefId",
        ),
        "dict": (
            "synthetic_def_id(",
            "SYNTHETIC_DICT_DEF_ID_BASE",
            "base_dict: lowered_base",
            "method_call_ref_bound_evidence(exact), defs, seen",
            "callee_ref: callee_ref",
            "validate_hir_binder_def_ids(lowered)",
        ),
        "infer_helpers": (
            "DictRef::Static(dict) =>",
            "TraitDispatch::Direct { dict: dict, extra_dicts: [] }",
            "DictRef::Simple(param) =>",
            "TraitDispatch::Dict { param: param }",
            "dict_closure_dicts: some([]), ty: getter_ty",
        ),
        "zonk": (
            "fn mark_zonk_direct_callee(",
            "fn clear_zonk_local_callee_marker(",
            "dict_closure_dicts: some([])",
            "ValueBindingKind::DirectCallable =>",
            "ValueBindingKind::ExternCallable =>",
            "ValueBindingKind::LocalBorrow =>\n"
            "                            clear_zonk_local_callee_marker(ident)",
            "clear_zonk_local_callee_marker(ident)",
        ),
        "derive": (
            "base_dict: DictRef::Simple(",
            "base_dict: DictRef::Static(",
            "base_dict: DictRef::Static(dict)",
        ),
        "cctx": (
            "pub struct CExactSlotRef",
            "pub struct CNameOnlySlotRef",
            "pub enum CRefKind",
            "pub struct CTypedRef",
            "pub value_slots_by_def_id: Map<Int, CExactSlotRef>",
            "pub name_only_slots: Map<Str, CNameOnlySlotRef>",
            "pub fn c_local_def(",
            "pub fn c_param_def(",
            "pub fn c_value_slot(",
            "pub fn c_exact_value_slot(",
            "pub fn c_name_only_value(",
            "pub fn c_identity_ledger_text(",
            "validate_identity_ledger(ctx)",
            "C identity ledger: receiver load",
            "value_slots_by_def_id: ctx.value_slots_by_def_id",
            "ctx.value_slots_by_def_id = saved.value_slots_by_def_id",
            "name_only_slots: ctx.name_only_slots",
            "ctx.name_only_slots = saved.name_only_slots",
        ),
        "cgen": (
            "fn resolve_c_dict_for_derived(mut ctx: CCtx, base_dict: DictRef) -> CTypedRef",
            "c_resolve_dict_ref(ctx, base_dict)",
            "FieldAction::Call { base_dict, extra_dicts }",
            '"${c_path}.identity-ledger"',
            "some(c_identity_ledger_text(ctx))",
        ),
        "cexpr": (
            "let found = match def_id",
            "some(id) => match c_exact_value_slot(ctx, name, id)",
            "let exact_local_callee = match callee",
            "let name_only_local_callee = match callee",
            "def_id: none",
            "c_match_name_only_slot(ctx, call_name, name)",
            "let closure_result = gen_c_closure_call(",
            "enum CCaptureProvenance",
            "Exact { reference: CTypedRef }",
            "NameOnly { reference: CTypedRef }",
            "provenance: CCaptureProvenance",
            "fn emit_c_capture_extract(",
            "fn emit_c_capture_store(",
            "fn emit_c_closure_construction(",
            "pub fn emit_c_receiver_load(",
            "closure_ref: CTypedRef",
            "fn consider_c_exact_reference(",
            "fn consider_c_required_name_only_capture(",
            "fn consider_c_optional_evidence_capture(",
            "C codegen: bound dictionary",
            "Final zonk proved a direct declaration/constructor",
            "A DefId-bearing local may never fall through by spelling",
            "exact local callee",
            "fn c_lookup_call_mut_flags(",
            "fn c_pattern_local(",
            "bind_c_root_pattern_after_success(",
            "C codegen: Drop '${name}' has no exact DefId slot",
            "C codegen: assignment '${name}' has no exact DefId",
            "fn c_is_name_only_dict_def_id(",
            "let is_name_only_dict = c_is_name_only_dict_def_id(def_id)",
            "let val = gen_c_expr(ctx, init)",
            "DictRef::Static(dict)",
            "fresh_tmp(ctx)",
        ),
        "cli": (
            'arg == "--internal-c-identity-ledger"',
            "identity_ledger: Bool",
            "parsed.identity_ledger)",
            "--internal-c-identity-ledger is single-file only",
        ),
        "provenance_fixture": (
            "fn __ring_T_Ord(mut value: Int)",
            "fn direct_global_with_ord_evidence<T: Ord>",
            "fn nested_trait_collision<T: Ord>",
            "let __ring_T_Ord = fn(value: Int)",
            "let __ring_self_ProvenanceTrait = fn()",
            "let __ring_ev_E = fn()",
            "let inner = fn()",
            "trait dictlocal_1",
            "enum ring",
            "fn dynamic_static_dict_collision<T: Eq>",
        ),
    }
    for label, tokens in required_tokens.items():
        source = sources[label]
        for token in tokens:
            if token not in source:
                errors.append(f"{label}: missing exact-slot contract {token!r}")
    for label, struct_name, expected_fields in (
            ("ast", "EffectOpDecl", ["name", "params", "return_type", "span"]),
            ("env", "EffectOpDef", ["name", "operation_ref", "params", "return_type"]),
            ("hir", "HEffectOp", ["name", "operation_ref", "params", "return_type"])):
        fields, field_error = _f0_struct_fields(sources[label], struct_name)
        if field_error:
            errors.append(field_error)
        elif fields is not None and [name for _, name in fields] != expected_fields:
            errors.append(f"{label}: {struct_name} retained effect-default fields")
    effect_def_fields, effect_def_error = _f0_struct_fields(
        sources["env"], "EffectDef")
    if effect_def_error:
        errors.append(effect_def_error)
    elif effect_def_fields is not None and "all_have_defaults" in (
            name for _, name in effect_def_fields):
        errors.append("env: EffectDef retained automatic default evidence")
    for label, token in (
            ("inventory", "EXECUTABLE_EFFECT_DEFAULT"),
            ("cctx", "DefaultEvidence"),
            ("cctx", "default_evidence"),
            ("cgen", "default_evidence"),
            ("cexpr", "default_evidence"),
            ("types", "IoEffect"),
            ("cctx", "local_fn_effects"),
            ("cctx", "effect_ops"),
            ("cgen", "scan_fn_effects"),
            ("cgen", "compute_transitive_effect_closure"),
            ("cgen", "compute_project_effect_closure"),
            ("cgen", "register_effect_ops_c")):
        if token in mask_ring_strings_and_comments(sources[label]):
            errors.append(f"{label}: retired effect authority {token!r} remains")
    for token in (
            '"Effect operation bodies are not supported in Ring 0.1"',
            "let _ = self.parse_block_expr()",
            "ops.push(EffectOpDecl { name: op_name, params: params,"):
        if token not in sources["parser"]:
            errors.append(f"parser: effect signature-only boundary misses {token!r}")
    for label, expected in (
            ("andor", 1), ("dict", 1), ("zonk", 1)):
        count = sources[label].count("callee_ref: callee_ref")
        if count != expected:
            errors.append(
                f"{label}: CalleeRef transport count was {count}, expected {expected}")
    builtin_value_body, builtin_value_error = extract_ring_function_body(
        sources["builtins"], "checker_only_builtin_values")
    if builtin_value_error:
        errors.append(builtin_value_error)
    elif not all(token in builtin_value_body for token in (
            '"Cell", builtin_value_site_from_tag(',
            "BUILTIN_VALUE_CELL_CONSTRUCTOR",
            '"alloc", builtin_value_site_from_tag(BUILTIN_VALUE_ALLOC)',
            '"dealloc", builtin_value_site_from_tag(BUILTIN_VALUE_DEALLOC)',
            '"ptr_copy", builtin_value_site_from_tag(BUILTIN_VALUE_PTR_COPY)',
            '"ptr_from_addr", builtin_value_site_from_tag(',
            "BUILTIN_VALUE_PTR_FROM_ADDR")):
        errors.append("builtins: checker-only value site relation drifted")
    elif "BUILTIN_VALUE_HASH_COMBINE" in builtin_value_body:
        errors.append("builtins: compiler-only hash atom entered source scope")
    if "CHECKER_ONLY_EXTERN_CALLABLES" in sources["hir"]:
        errors.append("hir: duplicate checker-only builtin manifest returned")
    builtin_fields, builtin_fields_error = _f0_struct_fields(
        sources["builtins"], "CheckerBuiltinValue")
    if builtin_fields_error:
        errors.append(builtin_fields_error)
    elif builtin_fields is not None and (
            [name for _, name in builtin_fields] != ["name", "symbol"] or
            any(is_public for is_public, _ in builtin_fields)):
        errors.append("builtins: checker-only value carrier is forgeable")
    checker_ctx_body, checker_ctx_error = extract_ring_function_body(
        sources["checker"], "new_infer_ctx")
    if checker_ctx_error:
        errors.append(checker_ctx_error)
    elif not all(token in checker_ctx_body for token in (
            "for builtin in checker_only_builtin_values()",
            "let name = checker_builtin_value_name(builtin)",
            "record_value_binding_kind(", "record_value_symbol_ref(",
            "checker_builtin_value_symbol(builtin)")):
        errors.append("checker: fixed builtin callable identity relation drifted")

    pattern_local_contract = (
        "fn c_pattern_local(\n"
        "    mut ctx: CCtx, name: Str, bindings: List<HPatternBinding>\n"
        ") -> Str {\n"
        "    if name == \"_\" {\n"
        "        return fresh_tmp(ctx)\n"
        "    }\n"
        "    let def_id = exact_pattern_def_id(bindings, name)\n"
        "    match c_exact_value_slot(ctx, name, def_id) {\n"
        "        some(slot) => c_exact_slot_c_name(slot),\n"
        "        none => c_local_def(ctx, name, some(def_id))\n"
        "    }\n"
        "}"
    )
    if sources["cexpr"].count(pattern_local_contract) != 1:
        errors.append(
            "cexpr: c_pattern_local wildcard must return only fresh_tmp before "
            "exact DefId lookup; named binding route drifted")

    if "let fn_scheme = ctx.env.lookup(name)" in sources["infer_decl"]:
        errors.append(
            "infer_decl: function HDecl DefId must not re-query a same-spelled env binding")
    infer_source = sources["infer"]
    if len(re.findall(r"\binfer_scoped_block\b", infer_source)) != 5:
        errors.append("infer: scoped-block helper must have one definition and four call sites")
    scoped_placements = (
        "infer_scoped_block(ctx, expr, some(subst))",
        "infer_scoped_block(ctx, body, some(subst))",
        "infer_scoped_block(ctx, then_branch, some(s))",
        "infer_scoped_block(ctx, eb, some(s))",
    )
    for placement in scoped_placements:
        if infer_source.count(placement) != 1:
            errors.append(f"infer: scoped-block placement drifted: {placement}")

    # Tracked gen0 accepts source OrPattern syntax but cannot lower a shared
    # body that reads payload variables bound by its alternatives.  Keep the
    # I-prime compiler implementation crossing-compatible without constraining
    # the language feature itself: each formerly shared traversal arm is an
    # explicit arm that delegates to a common helper.
    crossing_split_inventory = (
        ("hir", "validate_hir_stmt",
         "HStmt::Let { name, def_id, init, .. }",
         "HStmt::Var { name, def_id, init, .. }",
         "validate_hir_local_binding("),
        ("hir", "validate_hir_expr",
         "HExpr::ListLit { elements, .. }",
         "HExpr::TupleLit { elements, .. }",
         "validate_hir_expr_values("),
    )
    crossing_bodies: dict[tuple[str, str], str] = {}
    for label, function_name, left, right, helper in crossing_split_inventory:
        key = (label, function_name)
        body = crossing_bodies.get(key)
        if body is None:
            body, extract_error = extract_ring_function_body(
                sources[label], function_name)
            if extract_error:
                errors.append(extract_error)
                continue
            crossing_bodies[key] = body
        for arm in (left, right):
            arm_token = f"{arm} =>"
            if body.count(arm_token) != 1:
                errors.append(
                    f"{function_name}: crossing split arm {arm!r} matched "
                    f"{body.count(arm_token)} times")
        if body.count(helper) != 2:
            errors.append(
                f"{function_name}: crossing helper {helper!r} matched "
                f"{body.count(helper)} times")
        combined = re.compile(
            rf"{re.escape(left)}\s*\|\s*{re.escape(right)}")
        if combined.search(mask_ring_strings_and_comments(body)):
            errors.append(
                f"{function_name}: payload-binding OrPattern arm regained")

    payload_or_pattern = re.compile(
        r"(?m)^\s*[A-Za-z_][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*\s*"
        r"(?:\{(?!\s*\.\.\s*\})[^{}\n]+\}|"
        r"\(\s*(?!\s*\))[^()\n]+\))\s*\|(?!\|)")
    for (label, function_name), body in crossing_bodies.items():
        match = payload_or_pattern.search(mask_ring_strings_and_comments(body))
        if match is not None:
            errors.append(
                f"{label}.{function_name}: payload-binding source OrPattern "
                f"remains at {match.group(0).strip()!r}")

    if sources["cexpr"].count("bind_c_root_pattern_after_success(") != 3:
        errors.append(
            "C or-pattern lowering must have one shared-slot helper and "
            "two success-edge calls")

    assign_body, assign_error = extract_ring_function_body(
        sources["cexpr"], "emit_c_assign")
    if assign_error:
        errors.append(assign_error)
    else:
        if "c_exact_value_slot(ctx, name, exact_def_id)" not in assign_body:
            errors.append("C assignment no longer selects the exact DefId slot")
        if "ctx.named_values" in assign_body:
            errors.append("DefId-bearing C assignment regained a name fallback")

    call_body, call_error = extract_ring_function_body(
        sources["cexpr"], "gen_c_call")
    if call_error:
        errors.append(call_error)
    elif not all(token in call_body for token in (
            "let exact_local_callee = match callee",
            "c_exact_value_slot(ctx, name, id)",
            "let name_only_local_callee = match callee",
            "def_id: none",
            "c_match_name_only_slot(ctx, call_name, name)",
            "c_ref_exact(slot)",
            "c_ref_name_only(matched.slot)",
            "c_ref_computed(",
            "let raw = match callee")):
        errors.append("callable provenance chain lost an explicit route")
    elif not (
        call_body.index("let exact_local_callee = match callee")
        < call_body.index("let name_only_local_callee = match callee")
        < call_body.index("let raw = match callee")
    ):
        errors.append("callable exact/name-only/global precedence drifted")
    elif not all(token in call_body for token in (
            "def_id: some(id), dict_closure_dicts",
            "some(_) => {}",
            "A DefId-bearing local may never fall through by spelling",
            "exact local callee '${name}' DefId ${id} has no slot")):
        errors.append("exact callee miss is not marker-gated/fail-loud")
    elif call_body.index(
            "exact local callee '${name}' DefId ${id} has no slot") > call_body.index(
            "let name_only_local_callee = match callee"):
        errors.append("exact callee miss panic occurs after a name/global route")

    direct_body, direct_error = extract_ring_function_body(
        sources["cexpr"], "gen_c_direct_call")
    if direct_error:
        errors.append(direct_error)
    elif (
        "c_name_only_value" in direct_body
        or "c_match_name_only_slot" in direct_body
    ):
        errors.append("direct/global call regained ambient name-only lookup")

    zonk_direct_body, zonk_direct_error = extract_ring_function_body(
        sources["zonk"], "zonk_direct_callee")
    if zonk_direct_error:
        errors.append(zonk_direct_error)
    elif not all(token in zonk_direct_body for token in (
            "ValueBindingKind::DirectCallable =>\n"
            "                            mark_zonk_direct_callee(ident)",
            "ValueBindingKind::ExternCallable =>\n"
            "                            mark_zonk_direct_callee(ident)",
            "ValueBindingKind::LocalBorrow =>\n"
            "                            clear_zonk_local_callee_marker(ident)")):
        errors.append("final zonk direct/extern/local marker authority drifted")

    marker_body, marker_error = extract_ring_function_body(
        sources["zonk"], "mark_zonk_direct_callee")
    if marker_error:
        errors.append(marker_error)
    elif (
        "dict_closure_dicts: some([])" not in marker_body
        or "resolved_name" in marker_body
    ):
        errors.append("direct callee marker regained spelling-based authority")

    clear_marker_body, clear_marker_error = extract_ring_function_body(
        sources["zonk"], "clear_zonk_local_callee_marker")
    if clear_marker_error:
        errors.append(clear_marker_error)
    elif "dict_closure_dicts: none" not in clear_marker_body:
        errors.append("LocalBorrow direct callee can retain a direct marker")

    resolve_value_body, resolve_value_error = extract_ring_function_body(
        sources["infer_helpers"], "resolve_value_ident")
    if resolve_value_error:
        errors.append(resolve_value_error)
    elif not all(token in resolve_value_body for token in (
            "ValueBindingKind::ConstGetter",
            "dict_closure_dicts: some([]), ty: getter_ty",
            "callee: getter")):
        errors.append("ConstGetter synthetic direct Call lacks explicit marker")

    map_index_body, map_index_error = extract_ring_function_body(
        sources["infer"], "infer_index_expr")
    if map_index_error:
        errors.append(map_index_error)
    elif not all(token in map_index_body for token in (
            "let callee_name = map_index_helper_identity()",
            "def_id: callee_scheme.def_id, dict_closure_dicts: none",
            "callee: callee",
            "resolved_dicts: resolved_dicts")):
        errors.append("map index helper bypasses exact final-zonk marker authority")

    emitter_manifests = (
        ("gen_c_lambda", (
            'let mut sig_parts: List<Str> = ["void* env"]',
            "let edge = c_new_closure_edge(ctx, lambda_name)",
            "emit_c_capture_extract(ctx, edge, identity, dest, i + 1)",
            'c_emit(ctx, "${env} = ring_alloc((int64_t)(sizeof(int64_t) + ${captures.len()} * sizeof(void*)), 15);")',
            'c_emit(ctx, "*(int64_t*)${env} = ${captures.len()};")',
            "emit_c_capture_store(ctx, edge, identity, env_ref, i + 1)",
            "emit_c_closure_construction(\n        ctx, edge, env_ref, lambda_name)",
        )),
        ("gen_c_closure_call", (
            'let mut cast_tys: List<Str> = ["void*"]',
            'let mut call_args: List<Str> = ["((void**)${closure_val})[1]"]',
            'cast_tys.push("void*")',
            'call_args.push(a)',
            'c_emit(ctx, "${t} = ((void* (*)(${cast_tys.join(", ")}))(((void**)${closure_val})[0]))(${call_args.join(", ")});")',
            "c_record_closure_call(",
        )),
        ("gen_c_bound_method_call", (
            "method_call_ref_bound_evidence(exact)",
            "trait_method_ref_callable_slot_index(",
            'emit_c_receiver_load(\n        ctx, dict_ref, method_idx + 1, "dict")',
            "gen_c_closure_call(ctx, cls_ref, call_args)",
        )),
        ("gen_c_ord_dispatch", (
            'emit_c_receiver_load(ctx, dict_ref, 1, "dict")',
            "gen_c_closure_call(ctx, cls_ref, [lhs, rhs])",
        )),
        ("gen_c_effect_op", (
            'emit_c_receiver_load(\n            ctx, ev_ref, idx + 1, "effect")',
            "gen_c_closure_call(ctx, closure_ref, arg_vals)",
        )),
    )
    for function_name, manifest in emitter_manifests:
        body, extract_error = extract_ring_function_body(
            sources["cexpr"], function_name)
        if extract_error:
            errors.append(extract_error)
            continue
        for token in manifest:
            if body.count(token) != 1:
                errors.append(
                    f"{function_name}: finite C grammar anchor {token!r} "
                    f"matched {body.count(token)} times")

    stmt_body, stmt_error = extract_ring_function_body(
        sources["cexpr"], "emit_c_stmt")
    if stmt_error:
        errors.append(stmt_error)
    elif not all(token in stmt_body for token in (
            "let is_name_only_dict = c_is_name_only_dict_def_id(def_id)",
            "let val = gen_c_expr(ctx, init)")):
        errors.append("Dict alias provenance is not derived from exact synthetic DefId")
    elif stmt_body.count("gen_c_expr(ctx, init)") != 2:
        # One Let and one Var arm; the Let arm must have no second init read.
        errors.append("statement lowering changed the exact one-read-per-init contract")

    lambda_body, lambda_error = extract_ring_function_body(
        sources["cexpr"], "gen_c_lambda")
    if lambda_error:
        errors.append(lambda_error)
    else:
        if lambda_body.count("match cap.provenance") != 2:
            errors.append(
                "lambda extraction/construction must both consume capture tags")
        for token in (
            "CCaptureProvenance::Exact { reference }",
            "CCaptureProvenance::NameOnly { reference }",
            "c_local_def_ref(",
            "c_local_ref(ctx, c_ref_key(reference))",
            "emit_c_capture_extract(ctx, edge, identity, dest, i + 1)",
            "emit_c_capture_store(ctx, edge, identity, env_ref, i + 1)",
        ):
            expected_count = 2 if token.startswith(
                "CCaptureProvenance::") else 1
            if lambda_body.count(token) != expected_count:
                errors.append(
                    f"gen_c_lambda capture provenance drifted: {token!r}")
        if "cap.def_id" in lambda_body or "cap.name" in lambda_body:
            errors.append(
                "lambda capture regained overloaded name/DefId proof")

    for function_name, tokens in (
        ("consider_c_exact_reference", (
            "some(id) => push_c_exact_capture(",
            "none => {}",
        )),
        ("push_c_exact_capture", (
            "CCaptureProvenance::Exact",
            "CCaptureProvenance::NameOnly",
            "Not free in the enclosing frame",
            "Exact use-time lookup remains fail-closed",
        )),
        ("push_c_name_only_capture", (
            "CCaptureProvenance::Exact",
            "CCaptureProvenance::NameOnly",
            "matched.canonical_key",
        )),
        ("consider_c_required_name_only_capture", (
            "c_match_name_only_slot",
            "Not free in the enclosing frame",
            "c_resolve_dict_ref is the loud",
            "none => return",
            "push_c_name_only_capture",
        )),
        ("consider_c_optional_evidence_capture", (
            "c_match_name_only_slot",
            "some(matched) => push_c_name_only_capture",
            "none => {}",
        )),
    ):
        body, extract_error = extract_ring_function_body(
            sources["cexpr"], function_name)
        if extract_error:
            errors.append(extract_error)
        elif not all(token in body for token in tokens):
            errors.append(
                f"{function_name}: capture provenance contract drifted")
        elif function_name in (
                "consider_c_exact_reference", "push_c_exact_capture") and (
                "c_name_only_value" in body
                or "c_match_name_only_slot" in body):
            errors.append(
                f"{function_name}: exact/global route consults name-only state")

    dict_id_body, dict_id_error = extract_ring_function_body(
        sources["cexpr"], "c_is_name_only_dict_def_id")
    if dict_id_error:
        errors.append(dict_id_error)
    elif "is_synthetic_dict_def_id(id)" not in dict_id_body:
        errors.append("Dict name-only provenance is not the synthetic DefId namespace")

    resolve_dict_body, resolve_dict_error = extract_ring_function_body(
        sources["cexpr"], "c_resolve_dict_ref")
    if resolve_dict_error:
        errors.append(resolve_dict_error)
    else:
        simple_arm = re.search(
            r"DictRef::Simple\(n\)\s*=>\s*\{(.*?)"
            r"DictRef::Static\(n\)\s*=>",
            resolve_dict_body,
            re.DOTALL,
        )
        if simple_arm is None:
            errors.append("DictRef::Simple resolver arm is not explicit")
        elif (
            "c_name_only_value(ctx, n)" not in simple_arm.group(1)
            or "bound dictionary" not in simple_arm.group(1)
            or "resolve_c_static_dict" in simple_arm.group(1)
        ):
            errors.append("DictRef::Simple regained a static/name fallback")
        if "DictRef::Static(n) => c_ref_static(resolve_c_static_dict(ctx, n), n)" not in resolve_dict_body:
            errors.append("DictRef::Static no longer selects singleton resolution")

    dispatch_body, dispatch_error = extract_ring_function_body(
        sources["cexpr"], "resolve_c_dispatch_dict")
    if dispatch_error:
        errors.append(dispatch_error)
    elif not all(token in dispatch_body for token in (
            "DictRef::Simple(param)",
            "DictRef::Static(dict)",
            "Direct wrapped dispatch has no trait tag")):
        errors.append("TraitDispatch Dict/Direct provenance is not strict")
    elif "DictRef::Simple(dict)" in dispatch_body:
        errors.append("TraitDispatch::Direct base regained name-only resolution")

    dispatch_capture_body, dispatch_capture_error = extract_ring_function_body(
        sources["cexpr"], "collect_c_dispatch_dict")
    if dispatch_capture_error:
        errors.append(dispatch_capture_error)
    elif not all(token in dispatch_capture_body for token in (
            "TraitDispatch::Dict { param } => consider_c_required_name_only_capture",
            "TraitDispatch::Direct { extra_dicts, .. }",
            "for ed in extra_dicts")):
        errors.append("TraitDispatch capture census lost explicit provenance")
    elif "ctx, dict" in dispatch_capture_body:
        errors.append("TraitDispatch::Direct static base is captured")

    dictref_capture_body, dictref_capture_error = extract_ring_function_body(
        sources["cexpr"], "collect_c_dictref_names")
    if dictref_capture_error:
        errors.append(dictref_capture_error)
    elif not all(token in dictref_capture_body for token in (
            "DictRef::Simple(name) => consider_c_required_name_only_capture",
            "DictRef::Static(_) => {}",
            "DictRef::Wrapped { inner_dicts, .. }")):
        errors.append("DictRef capture census lost Simple/Static/Wrapped tags")
    elif "ctx, dict" in dictref_capture_body:
        errors.append("DictRef::Wrapped static base is captured")

    bound_dispatch_body, bound_dispatch_error = extract_ring_function_body(
        sources["cexpr"], "gen_c_bound_method_call")
    if bound_dispatch_error:
        errors.append(bound_dispatch_error)
    elif not all(token in bound_dispatch_body for token in (
            "method_call_ref_bound_evidence(exact)",
            "trait_method_ref_callable_slot_index(",
            "method_call_ref_bound(exact)")):
        errors.append("bound method dispatch does not consume exact evidence/slot")
    elif any(token in bound_dispatch_body for token in (
            "method_call_ref_name", "trait_method_order", "c_builtin_method_index")):
        errors.append("bound method dispatch regained name/order fallback")

    derived_resolve_body, derived_resolve_error = extract_ring_function_body(
        sources["cgen"], "resolve_c_dict_for_derived")
    if derived_resolve_error:
        errors.append(derived_resolve_error)
    elif (
        "base_dict: DictRef" not in sources["cgen"]
        or "c_resolve_dict_ref(ctx, base_dict)" not in derived_resolve_body
        or "DictRef::Simple" in derived_resolve_body
    ):
        errors.append("derived FieldAction base does not retain DictRef provenance")

    wildcard_body, wildcard_error = extract_ring_function_body(
        sources["cexpr"], "c_for_binding_local")
    if wildcard_error:
        errors.append(wildcard_error)
    elif "fresh_tmp(ctx)" not in wildcard_body or "__ring_for_wildcard" in wildcard_body:
        errors.append("for wildcard regained an ambient name-only binding")

    for source_name in ("hir", "infer", "infer_decl", "dict", "cexpr"):
        if "DictDispatchInfo" in sources[source_name] or (
                "dict_dispatch" in sources[source_name]):
            errors.append(f"{source_name}: retired DictDispatchInfo authority returned")
    if sources["infer"].count(
            "bound_evidence = some(DictRef::Simple(") != 1 or (
            "make_bound_method_call_ref(\n"
            "                        bound, evidence, callee_type," not in
            sources["infer"]):
        errors.append("infer bound method producer is not uniquely Simple/exact")
    if sources["infer_decl"].count(
            "DictRef::Static(dict_name), tm.ty") != 1 or (
            "make_bound_method_call_ref(" not in sources["infer_decl"]):
        errors.append("infer_decl delegated bound evidence is not uniquely Static")
    for label in ("derive", "dict", "cgen"):
        if "FieldAction::Call { dict_name" in sources[label]:
            errors.append(f"{label}: FieldAction base lost explicit DictRef tag")
    if not all(token in sources["derive"] for token in (
            "base_dict: DictRef::Simple(",
            "base_dict: DictRef::Static(",
            "some(DictRef::Wrapped { dict, inner_dicts, .. })",
            "base_dict: DictRef::Static(dict)")):
        errors.append("derive FieldAction Simple/Static/Wrapped inventory drifted")
    for function_name, bound_token in (
        ("resolve_field_action", (
            "base_dict: DictRef::Simple(\n"
            "                    trait_bound_param_name(param_name, trait_name))"
        )),
        ("resolve_hash_field_action", (
            "base_dict: DictRef::Simple(\n"
            "                    trait_bound_param_name(param_name, \"Hash\"))"
        )),
    ):
        body, extract_error = extract_ring_function_body(
            sources["derive"], function_name)
        if extract_error:
            errors.append(extract_error)
        elif body.count(bound_token) != 1:
            errors.append(
                f"{function_name}: type-variable FieldAction base is not Simple")

    direct_fixture_contract = (
        "fn direct_global_with_ord_evidence<T: Ord>(left: T, right: T) -> Int {\n"
        "    if left < right { __ring_T_Ord(5) } else { 0 }\n"
        "}")
    if sources["provenance_fixture"].count(direct_fixture_contract) != 1:
        errors.append(
            "direct global/evidence fixture regained a same-named local or lost a route")

    mut_flags_body, mut_flags_error = extract_ring_function_body(
        sources["cexpr"], "c_lookup_call_mut_flags")
    if mut_flags_error:
        errors.append(mut_flags_error)
    else:
        exact_slot_lookup = "c_exact_value_slot(ctx, name, id)"
        module_lookup = "ctx.fn_mut_params.get(resolved_key)"
        if (
            exact_slot_lookup not in mut_flags_body
            or "none => match dict_closure_dicts" not in mut_flags_body
            or "Unmarked exact local: gen_c_call will fail loud" not in mut_flags_body
            or "none => { return none }" not in mut_flags_body
            or "c_match_name_only_slot(ctx, call_name, name)" not in mut_flags_body
            or mut_flags_body.index(exact_slot_lookup) > mut_flags_body.index(module_lookup)
            or mut_flags_body.index(
                "c_match_name_only_slot(ctx, call_name, name)")
                > mut_flags_body.index(module_lookup)
        ):
            errors.append(
                "exact/local callable mut flags are not gated before module metadata")

    name_match_body, name_match_error = extract_ring_function_body(
        sources["cexpr"], "c_match_name_only_slot")
    if name_match_error:
        errors.append(name_match_error)
    else:
        resolved_lookup = "c_name_only_value(ctx, resolved_key)"
        bare_lookup = "c_name_only_value(ctx, bare_key)"
        if not all(token in name_match_body for token in (
                resolved_lookup,
                "canonical_key: resolved_key",
                "if bare_key == resolved_key { return none }",
                bare_lookup,
                "canonical_key: bare_key")):
            errors.append("resolved-vs-bare name-only key match is not explicit")
        elif name_match_body.index(resolved_lookup) > name_match_body.index(bare_lookup):
            errors.append("bare name-only key precedes resolved canonical key")

    name_only_body, name_only_error = extract_ring_function_body(
        sources["cctx"], "c_name_only_value")
    if name_only_error:
        errors.append(name_only_error)
    elif (
        "ctx.name_only_slots.get(name)" not in name_only_body
        or "ctx.named_values" in name_only_body
    ):
        errors.append("backend name-only lookup is not an independent slot map")

    exact_local_body, exact_local_error = extract_ring_function_body(
        sources["cctx"], "c_local_def")
    if exact_local_error:
        errors.append(exact_local_error)
    elif "name_only_slots" in exact_local_body:
        errors.append("exact source local registration contaminates name-only slots")

    push_body, push_error = extract_ring_function_body(
        sources["cctx"], "c_push_fn")
    pop_body, pop_error = extract_ring_function_body(
        sources["cctx"], "c_pop_fn")
    if push_error:
        errors.append(push_error)
    elif pop_error:
        errors.append(pop_error)
    else:
        for domain in (
            "name_only_slots", "value_slots_by_def_id",
        ):
            if (
                f"{domain}: ctx.{domain}" not in push_body
                or f"ctx.{domain} = map_new()" not in push_body
                or f"ctx.{domain} = saved.{domain}" not in pop_body
            ):
                errors.append(
                    f"c_push/c_pop does not independently restore {domain}")

    direct_predicate_body, direct_predicate_error = extract_ring_function_body(
        sources["hir"], "is_exact_direct_call_ident")
    if direct_predicate_error:
        errors.append(direct_predicate_error)
    elif not all(token in direct_predicate_body for token in (
            "HExpr::Ident {",
            "def_id: some(_), dict_closure_dicts: some(_)",
            "=> true",
            "_ => false")):
        errors.append("direct-call predicate is broader than exact marked Ident")

    for function_name, required in (
        ("check_effect_decl", (
            "def_id: none, is_mutable: false",
        )),
        ("check_trait_decl", (
            "let trait_param_def_id = ctx.env.fresh_def_id()",
            "def_id: some(trait_param_def_id)",
        )),
        ("check_trait_default_body", (
            "let exact_trait_def_id = match p.def_id",
            "def_id: some(exact_trait_def_id)",
        )),
    ):
        body, extract_error = extract_ring_function_body(
            sources["infer_decl"], function_name)
        if extract_error:
            errors.append(extract_error)
        else:
            for token in required:
                if body.count(token) != 1:
                    errors.append(
                        f"{function_name}: exact declaration parameter contract "
                        f"{token!r} matched {body.count(token)} times")

    bind_pattern_body, bind_pattern_error = extract_ring_function_body(
        sources["infer_ctx"], "bind_pattern")
    if bind_pattern_error:
        errors.append(bind_pattern_error)
    else:
        authority_tokens = (
            "if patterns.len() == 0",
            "report_duplicate_or_pattern_bindings(",
            "same_or_pattern_binding_names(",
            "if !binding_sets_valid",
            "fail.raise(CompileError {})",
            "authority.scheme.ty, candidate.ty",
            "ctx.env.bind(authority.name, authority.scheme)",
        )
        for token in authority_tokens:
            if token not in bind_pattern_body:
                errors.append(
                    f"bind_pattern OrPattern authority missing {token!r}")
        if "expected_names.len() > 0" in bind_pattern_body:
            errors.append(
                "bind_pattern incorrectly rejects legal empty binding sets")

    for function_name, pattern_name in (
        ("infer_match", "match_pattern"),
        ("infer_catch", "catch_pattern"),
        ("infer_if_let_from_result", "iflet_pattern"),
    ):
        body, extract_error = extract_ring_function_body(
            sources["infer"], function_name)
        if extract_error:
            errors.append(extract_error)
            continue
        bind_anchor = f"bind_pattern(ctx, {pattern_name}"
        transport_match = re.search(
            rf"exact_pattern_bindings\s*\(\s*ctx\.env\s*,\s*"
            rf"{re.escape(pattern_name)}\s*\)",
            body,
        )
        if bind_anchor not in body or transport_match is None:
            errors.append(
                f"{function_name}: missing bind_pattern→exact HIR transport")
        elif body.index(bind_anchor) > transport_match.start():
            errors.append(
                f"{function_name}: HIR extracts pattern IDs before authority")

    # I-prime is identity only: the S-prime producer split and A-prime Take /
    # ownership metadata must remain absent from this checkpoint.
    forbidden = {
        "hir": (
            "OwnershipMetadata", "Take {", "pub dict_param: Str",
            "Call { dict_name: Str",
        ),
        "cctx": ("exact_value_names", "name_only_values"),
        "cexpr": (
            'starts_with("__ring_dictlocal_")',
            "let is_name_only_dict = match init",
            "c_is_name_only_dict_init",
            "init_for_classification",
            "init_for_codegen",
            "cap.def_id",
            "cap.name",
            "DictRef::Simple(dict)",
            'c_local(ctx, "__ring_for_wildcard")',
        ),
        "cgen": ("FieldAction::Call { dict_name",),
    }
    for label, tokens in forbidden.items():
        for token in tokens:
            if token in sources[label]:
                errors.append(f"{label}: I-prime imported forbidden {token!r}")
    return errors


def identity_candidate_case_root(parent: Path, case_name: str) -> Path:
    """Create one exclusive candidate-gate root; never share/fallback."""
    case_root = parent / case_name
    try:
        case_root.mkdir(parents=False, exist_ok=False)
    except OSError as exc:
        raise RuntimeError(
            f"cannot create identity candidate case root {case_root}: {exc}"
        ) from exc
    if not case_root.is_dir():
        raise RuntimeError(
            f"identity candidate case root is not a directory: {case_root}")
    return case_root


_IDENTITY_ROOT_TOKEN = b"@RING_IDENTITY_FRESH_ROOT@"


def canonicalize_identity_stdout_root(
    raw: bytes, fresh_root: Path, *, expected_count: int,
) -> Tuple[Optional[bytes], Optional[str]]:
    """Replace exactly one reviewed fresh-root path prefix, nothing else."""
    root_bytes = os.fsencode(str(fresh_root.resolve()))
    occurrences: List[Tuple[int, int]] = []
    offset = 0
    separators = (b"/", b"\\")
    allowed_before = b" \t='\"("
    while True:
        index = raw.find(root_bytes, offset)
        if index < 0:
            break
        end = index + len(root_bytes)
        before_ok = index == 0 or raw[index - 1:index] in [
            bytes([value]) for value in allowed_before]
        after_ok = end < len(raw) and raw[end:end + 1] in separators
        if not before_ok or not after_ok:
            return None, (
                "fresh-root occurrence is not a complete path prefix at "
                f"byte {index}")
        occurrences.append((index, end))
        offset = end
    if len(occurrences) != expected_count:
        return None, (
            f"fresh-root replacement count {len(occurrences)} != "
            f"{expected_count}")
    pieces: List[bytes] = []
    cursor = 0
    for begin, end in occurrences:
        pieces.append(raw[cursor:begin])
        pieces.append(_IDENTITY_ROOT_TOKEN)
        cursor = end
    pieces.append(raw[cursor:])
    return b"".join(pieces), None


def identity_stdout_canonicalization_errors() -> List[str]:
    errors: List[str] = []
    root = Path("C:/fresh/identity-case")
    root_bytes = os.fsencode(str(root.resolve()))
    valid = b"Compiled: " + root_bytes + b"/out/case.o\n"
    canonical, valid_error = canonicalize_identity_stdout_root(
        valid, root, expected_count=1)
    if valid_error or canonical is None:
        return [f"valid fresh-root canonicalization failed: {valid_error}"]
    expected = b"Compiled: " + _IDENTITY_ROOT_TOKEN + b"/out/case.o\n"
    if canonical != expected:
        errors.append("fresh-root canonicalization changed bytes outside root")
    invalid_cases = {
        "zero": b"Compiled: C:/elsewhere/out/case.o\n",
        "extra": valid + valid,
        "near-prefix": b"Compiled: " + root_bytes + b"-other/out/case.o\n",
        "wrong-separator": b"Compiled: " + root_bytes + b"Xout/case.o\n",
    }
    for label, value in invalid_cases.items():
        _, error = canonicalize_identity_stdout_root(
            value, root, expected_count=1)
        if error is None:
            errors.append(f"fresh-root canonicalization mutation escaped: {label}")
    changed_diagnostic = valid.replace(b"Compiled:", b"Changed!:")
    changed, changed_error = canonicalize_identity_stdout_root(
        changed_diagnostic, root, expected_count=1)
    if changed_error or changed == canonical:
        errors.append("non-path diagnostic mutation was normalized away")
    unrelated = b"candidate=C:/tools/ring.exe source=C:/src/input.ring\n" + valid
    unrelated_canonical, unrelated_error = canonicalize_identity_stdout_root(
        unrelated, root, expected_count=1)
    if unrelated_error or unrelated_canonical is None or not unrelated_canonical.startswith(
            b"candidate=C:/tools/ring.exe source=C:/src/input.ring\n"):
        errors.append("canonicalizer touched candidate/source/tool paths")
    return errors


@dataclass(frozen=True)
class IdentityCandidateArtifacts:
    mode: str
    case_root: Path
    stdout: bytes
    stderr: bytes
    c_bytes: bytes
    object_bytes: bytes
    ledger_bytes: Optional[bytes]
    verdict: dict[str, Any]
    audit: dict[str, Any]
    archive_path: Path
    archive_sha256: str


def run_identity_candidate_mode(
    ring_exe: str, fixture: str, case_root: Path, evidence_log: List[str],
    *, ledger: bool,
) -> Tuple[Optional[IdentityCandidateArtifacts], Optional[str]]:
    mode = "on" if ledger else "off"
    out_dir = case_root / "out"
    evidence_dir = case_root / "one-shot"
    try:
        out_dir.mkdir(parents=False, exist_ok=False)
        evidence_dir.mkdir(parents=False, exist_ok=False)
    except OSError as exc:
        return None, f"cannot create fresh {mode} candidate roots: {exc}"
    if list(out_dir.iterdir()):
        return None, f"fresh {mode} output root is not empty"

    fixture_path = (REPO / fixture).resolve()
    base = fixture_path.stem
    c_path = out_dir / f"{base}.c"
    object_path = out_dir / f"{base}.o"
    ledger_path = Path(str(c_path) + ".identity-ledger")
    if ledger_path.exists():
        return None, f"fresh {mode} ledger unexpectedly exists"
    clang = _resolved_executable("clang")
    if clang is None:
        return None, "identity candidate gate cannot resolve clang"
    environment = dict(os.environ)
    environment.pop(IDENTITY_CANDIDATE_ENV, None)
    environment.pop(IDENTITY_EVIDENCE_ROOT_ENV, None)
    argv = [
        str(Path(ring_exe).resolve()), "build", str(fixture_path),
        "--target=c", f"--out-dir={out_dir}", "--no-c-lines",
    ]
    if ledger:
        argv.append("--internal-c-identity-ledger")
    expected_names = {c_path.name, object_path.name}
    if ledger:
        expected_names.add(ledger_path.name)

    def validate_artifacts(_outcome: Mapping[str, Any]) -> None:
        actual_names = {path.name for path in out_dir.iterdir()}
        if actual_names != expected_names:
            raise OneShotResultSchemaError(
                f"{mode} artifact inventory {actual_names} != {expected_names}")
        for required in (c_path, object_path):
            if not required.is_file():
                raise OneShotResultSchemaError(
                    f"{mode} candidate omitted {required.name}")
        if ledger and not ledger_path.is_file():
            raise OneShotResultSchemaError("on candidate omitted identity ledger")
        if not ledger and ledger_path.exists():
            raise OneShotResultSchemaError("off candidate emitted identity ledger")

    limits = OneShotLimits(
        wall_seconds=300,
        stdout_cap_bytes=1024 * 1024,
        stderr_cap_bytes=1024 * 1024,
        job_memory_bytes=(12 * 1024 * 1024 * 1024 if os.name == "nt" else None),
        active_process_limit=(5 if os.name == "nt" else None),
    )
    spec = OneShotSpec(
        evidence_dir=evidence_dir.resolve(),
        gate_id=f"identity-ledger-{mode}",
        argv=tuple(argv),
        reviewed_argv=tuple(argv),
        cwd=REPO.resolve(),
        env=environment,
        reviewed_env=tuple(sorted(environment.items())),
        limits=limits,
    )
    verdict: Optional[dict[str, Any]] = None
    wrapper_error: Optional[str] = None
    try:
        verdict = run_one_shot(spec, result_validator=validate_artifacts)
    except Exception as exc:
        wrapper_error = str(exc)
    audit = audit_one_shot_attempt(evidence_dir)
    archive_path = case_root.parent / f"{case_root.name}.tar"
    archive_error: Optional[str] = None
    try:
        create_one_shot_archive(case_root, archive_path)
        archive_sha256 = _sha256_file(archive_path)
    except Exception as exc:
        archive_error = str(exc)
        archive_sha256 = "unavailable"
    archive_detail = (
        f"sha256={archive_sha256}" if archive_error is None
        else f"error={archive_error}")
    evidence_log.append(
        f"{case_root.name}:raw={evidence_dir};audit={audit['state']}/"
        f"{audit['status']};archive={archive_path};{archive_detail}")
    if wrapper_error is not None:
        return None, (
            f"{mode} B-188 wrapper failed: {wrapper_error}; raw={evidence_dir}; "
            f"archive={archive_path}; {archive_detail}")
    assert verdict is not None
    if verdict["status"] != "success":
        return None, (
            f"{mode} candidate failed as {verdict['classification']}; "
            f"raw={evidence_dir}; archive={archive_path}; "
            f"{archive_detail}")
    if audit["state"] != "complete" or audit["status"] != "success":
        return None, (
            f"{mode} one-shot recovery audit failed: {audit}; "
            f"archive={archive_path}; archive_sha256={archive_sha256}")
    if archive_error is not None:
        return None, (
            f"cannot archive {mode} identity artifacts: {archive_error}; "
            f"raw={evidence_dir}")
    try:
        stdout = (evidence_dir / "stdout.raw").read_bytes()
        stderr = (evidence_dir / "stderr.raw").read_bytes()
        c_bytes = c_path.read_bytes()
        object_bytes = object_path.read_bytes()
        ledger_bytes = ledger_path.read_bytes() if ledger else None
    except OSError as exc:
        return None, (
            f"cannot read retained {mode} identity artifacts: {exc}; "
            f"raw={evidence_dir}; archive={archive_path}")
    return IdentityCandidateArtifacts(
        mode=mode,
        case_root=case_root,
        stdout=stdout,
        stderr=stderr,
        c_bytes=c_bytes,
        object_bytes=object_bytes,
        ledger_bytes=ledger_bytes,
        verdict=verdict,
        audit=audit,
        archive_path=archive_path,
        archive_sha256=archive_sha256,
    ), None


def coff_object_timestamp_equality_errors(
    label: str, left: bytes, right: bytes,
) -> List[str]:
    errors: List[str] = []
    for side, data in (("left", left), ("right", right)):
        if len(data) < 20:
            errors.append(f"{label}: invalid COFF {side} header length {len(data)}")
            continue
        machine = int.from_bytes(data[0:2], "little")
        section_count = int.from_bytes(data[2:4], "little")
        if machine != 0x8664:
            errors.append(
                f"{label}: invalid COFF {side} machine 0x{machine:04X}")
        if not 1 <= section_count <= 96:
            errors.append(
                f"{label}: invalid COFF {side} section count {section_count}")
    if errors:
        return errors
    if len(left) != len(right):
        return [
            f"{label}: invalid COFF object length mismatch "
            f"{len(left)} != {len(right)}"
        ]

    diff_offsets = {
        offset for offset, (a, b) in enumerate(zip(left, right)) if a != b
    }
    allowed_offsets = {4, 5, 6, 7}
    if not diff_offsets.issubset(allowed_offsets):
        outside = sorted(diff_offsets - allowed_offsets)
        return [f"{label}: COFF diff outside timestamp at offsets {outside}"]

    normalized_left = bytearray(left)
    normalized_right = bytearray(right)
    normalized_left[4:8] = b"\x00\x00\x00\x00"
    normalized_right[4:8] = b"\x00\x00\x00\x00"
    if bytes(normalized_left) != bytes(normalized_right):
        return [f"{label}: COFF diff outside timestamp after normalization"]
    return []


def default_body_identity_generated_c_errors(
    ring_exe: str, evidence_root: Path, evidence_log: List[str],
) -> List[str]:
    """Run off/on/on H+T acceptance through durable one-shot receipts."""
    errors: List[str] = []
    fixture = "tests/cases/provenance_b_capture_identity.ring"
    candidate_before = _sha256_file(Path(ring_exe))
    runs: List[IdentityCandidateArtifacts] = []
    for case_name, ledger in (("off", False), ("on1", True), ("on2", True)):
        try:
            case_root = identity_candidate_case_root(evidence_root, case_name)
        except RuntimeError as exc:
            errors.append(str(exc))
            return errors
        artifacts, run_error = run_identity_candidate_mode(
            ring_exe, fixture, case_root, evidence_log, ledger=ledger)
        if run_error:
            errors.append(run_error)
            return errors
        assert artifacts is not None
        runs.append(artifacts)
    off, on1, on2 = runs

    for label, left, right in (
            ("off/on1 C", off.c_bytes, on1.c_bytes),
            ("on1/on2 C", on1.c_bytes, on2.c_bytes),
            ("off/on1 stderr", off.stderr, on1.stderr),
            ("on1/on2 stderr", on1.stderr, on2.stderr),
    ):
        if left != right:
            errors.append(f"identity ledger changed {label} bytes")

    errors.extend(coff_object_timestamp_equality_errors(
        "off/on1 object", off.object_bytes, on1.object_bytes))
    errors.extend(coff_object_timestamp_equality_errors(
        "on1/on2 object", on1.object_bytes, on2.object_bytes))

    canonical_stdout: List[bytes] = []
    for run in runs:
        canonical, canonical_error = canonicalize_identity_stdout_root(
            run.stdout, run.case_root, expected_count=1)
        if canonical_error:
            errors.append(f"{run.mode} stdout identity: {canonical_error}")
            continue
        assert canonical is not None
        canonical_stdout.append(canonical)
    if len(canonical_stdout) == 3 and not (
            canonical_stdout[0] == canonical_stdout[1] == canonical_stdout[2]):
        errors.append("identity ledger changed non-path stdout diagnostics")

    if off.ledger_bytes is not None:
        errors.append("off mode unexpectedly retained ledger bytes")
    if on1.ledger_bytes is None or on2.ledger_bytes is None:
        errors.append("on mode omitted ledger bytes")
    elif on1.ledger_bytes != on2.ledger_bytes:
        errors.append("identity ledger bytes/hash are nondeterministic")
    else:
        ledger_events, ledger_errors = parse_identity_ledger(on1.ledger_bytes)
        errors.extend(ledger_errors)
        if ledger_events is not None:
            domains = {event.domain for event in ledger_events}
            for required in ("exact", "name-only", "computed", "fresh"):
                if required not in domains:
                    errors.append(
                        f"identity ledger fixture omitted {required} domain")
            keys = {event.canonical_key for event in ledger_events}
            for required_key in (
                "__ring_T_Ord", "__ring_self_ProvenanceTrait", "__ring_ev_E"):
                if required_key not in keys:
                    errors.append(
                        f"identity ledger omitted receiver key {required_key}")
        ledger_path_token = str(on1.case_root).encode("utf-8")
        for label, data in (
            ("C", on1.c_bytes), ("object", on1.object_bytes)):
            if b"RING-C-IDENTITY-LEDGER" in data or ledger_path_token in data:
                errors.append(f"identity ledger path/content leaked into {label}")

    if _sha256_file(Path(ring_exe)) != candidate_before:
        errors.append("candidate executable changed across off/on ledger runs")
    return errors


IR_IDENTITY_F0_PATH = REPO / "compiler" / "ir_identity.ring"
RESOURCE_MODEL_F0_PATH = REPO / "compiler" / "resource_model.ring"
F0_SEMANTIC_MUTATION_COUNT = 42
F0_SCOPE_GUARD_COUNT = 9


def _f0_function_span(
    source: str, function_name: str,
) -> Tuple[Optional[Tuple[int, int]], Optional[str]]:
    masked = mask_ring_strings_and_comments(source)
    pattern = re.compile(
        rf"\bfn\s+{re.escape(function_name)}\s*"
        rf"\([^{{}}]*\)[^{{}}\n]*\{{")
    matches = list(pattern.finditer(masked))
    if len(matches) != 1:
        return None, f"F0 function {function_name} found {len(matches)} times"
    open_index = masked.rfind("{", matches[0].start(), matches[0].end())
    try:
        close_index = matching_delimiter(masked, open_index, "{", "}")
    except ValueError as exc:
        return None, f"F0 function {function_name}: {exc}"
    return (open_index + 1, close_index), None


def _f0_function_body(
    source: str, function_name: str,
) -> Tuple[Optional[str], Optional[str]]:
    span, error = _f0_function_span(source, function_name)
    if error:
        return None, error
    assert span is not None
    return source[span[0]:span[1]], None


def _f0_mutate_function_once(
    source: str, function_name: str, anchor: str, replacement: str,
) -> Tuple[Optional[str], Optional[str]]:
    span, error = _f0_function_span(source, function_name)
    if error:
        return None, error
    assert span is not None
    body = source[span[0]:span[1]]
    count = body.count(anchor)
    if count != 1:
        return None, (
            f"F0 function {function_name} mutation anchor matched {count} times")
    return (
        source[:span[0]] + body.replace(anchor, replacement, 1) +
        source[span[1]:], None)


def _f0_const_list_span(
    source: str, name: str,
) -> Tuple[Optional[Tuple[int, int]], Optional[str]]:
    masked = mask_ring_strings_and_comments(source)
    pattern = re.compile(
        rf"\bconst\s+{re.escape(name)}\s*:\s*List<(?:Int|Bool)>\s*=\s*\[")
    matches = list(pattern.finditer(masked))
    if len(matches) != 1:
        return None, f"F0 const {name} found {len(matches)} times"
    open_index = masked.rfind("[", matches[0].start(), matches[0].end())
    try:
        close_index = matching_delimiter(masked, open_index, "[", "]")
    except ValueError as exc:
        return None, f"F0 const {name}: {exc}"
    return (open_index + 1, close_index), None


def _f0_int_list(
    source: str, name: str,
) -> Tuple[Optional[List[int]], Optional[str]]:
    span, error = _f0_const_list_span(source, name)
    if error:
        return None, error
    assert span is not None
    values: List[int] = []
    for raw in source[span[0]:span[1]].split(","):
        token = raw.strip()
        if not token:
            continue
        if re.fullmatch(r"[0-9]+", token) is None:
            return None, f"F0 const {name} has non-Int token {token!r}"
        values.append(int(token))
    return values, None


def _f0_bool_list(
    source: str, name: str,
) -> Tuple[Optional[List[bool]], Optional[str]]:
    span, error = _f0_const_list_span(source, name)
    if error:
        return None, error
    assert span is not None
    values: List[bool] = []
    for raw in source[span[0]:span[1]].split(","):
        token = raw.strip()
        if not token:
            continue
        if token not in {"true", "false"}:
            return None, f"F0 const {name} has non-Bool token {token!r}"
        values.append(token == "true")
    return values, None


def _f0_replace_const_list(
    source: str, name: str, values: List[object],
) -> Tuple[Optional[str], Optional[str]]:
    span, error = _f0_const_list_span(source, name)
    if error:
        return None, error
    assert span is not None
    body = ", ".join(
        ("true" if value else "false") if isinstance(value, bool)
        else str(value)
        for value in values)
    return source[:span[0]] + body + source[span[1]:], None


def _f0_struct_fields(
    source: str, name: str,
) -> Tuple[Optional[List[Tuple[bool, str]]], Optional[str]]:
    masked = mask_ring_strings_and_comments(source)
    pattern = re.compile(rf"\bpub\s+struct\s+{re.escape(name)}\s*\{{")
    matches = list(pattern.finditer(masked))
    if len(matches) != 1:
        return None, f"F0 struct {name} found {len(matches)} times"
    open_index = masked.rfind("{", matches[0].start(), matches[0].end())
    try:
        close_index = matching_delimiter(masked, open_index, "{", "}")
    except ValueError as exc:
        return None, f"F0 struct {name}: {exc}"
    body = masked[open_index + 1:close_index]
    fields = [
        (match.group(1) is not None, match.group(2))
        for match in re.finditer(
            r"(?m)^\s*(?:(pub)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:", body)
    ]
    return fields, None


def _f0_lattice_errors(
    label: str, table: List[int], ranks: List[int], count: int,
) -> List[str]:
    errors: List[str] = []
    if len(table) != count * count:
        return [f"{label} join table has {len(table)} cells"]
    if len(ranks) != count:
        return [f"{label} rank table has {len(ranks)} cells"]
    if any(value < 0 or value >= count for value in table):
        return [f"{label} join table contains invalid tag"]

    def join(left: int, right: int) -> int:
        return table[left * count + right]

    def leq(left: int, right: int) -> bool:
        return join(left, right) == right

    for left in range(count):
        if join(left, left) != left:
            errors.append(f"{label} join is not idempotent at {left}")
        if join(0, left) != left or join(left, 0) != left:
            errors.append(f"{label} tag 0 is not Bottom at {left}")
        for right in range(count):
            if join(left, right) != join(right, left):
                errors.append(f"{label} join is not commutative at {left},{right}")
            result = join(left, right)
            if ranks[result] < ranks[left] or ranks[result] < ranks[right]:
                errors.append(f"{label} rank decreases at {left},{right}")
            if leq(left, right) and leq(right, left) and left != right:
                errors.append(f"{label} order is not antisymmetric at {left},{right}")
            for third in range(count):
                if join(join(left, right), third) != join(
                        left, join(right, third)):
                    errors.append(
                        f"{label} join is not associative at {left},{right},{third}")
                if leq(left, right) and leq(right, third) and not leq(left, third):
                    errors.append(
                        f"{label} order is not transitive at {left},{right},{third}")
    return errors


def _f0_require_function_tokens(
    source: str, function_name: str, tokens: Tuple[str, ...],
    errors: List[str],
) -> str:
    body, body_error = _f0_function_body(source, function_name)
    if body_error:
        errors.append(body_error)
        return ""
    assert body is not None
    for token in tokens:
        if token not in body:
            errors.append(f"F0 {function_name} misses relation {token!r}")
    return body


def ir_identity_f0_contract_errors(source: str) -> List[str]:
    errors: List[str] = []
    masked = mask_ring_strings_and_comments(source)
    if re.search(r"(?m)^\s*use\s+", masked):
        errors.append("IR identity F0 imports another compiler module")
    for forbidden in (
        "ParamMode", "SlotFlow", "LogicalOwnershipShape", "PhysicalRcShape",
        "IdentityManifest", "ModelStage", "NormalizedResourceModel",
        "FinalFrozenResourceModel", "PlannedResourceModel",
        "VerifiedResourceModel", "ProjectionPath", "OwnershipMetadata",
        "FnMeta", "HExpr", "IdentityCounter", "next_identity",
        "fresh_identity", "identity_name_fallback", "hash_identity",
        "resolver_lookup",
    ):
        if forbidden in masked:
            errors.append(f"IR identity F0 gained forbidden authority {forbidden!r}")

    private_structs = {
        "SymbolRef": [
            "origin_module_key", "namespace_kind", "canonical_payload",
            "declaration_site_path"],
        "ModuleBodyRef": ["origin_module_key", "declaration_site_path"],
        "PathOwnerRef": ["value"],
        "PathRef": ["owner", "normalized_child_path", "role"],
        "SlotRef": ["value"],
        "CalleeRef": ["value"],
        "GlobalNominalRef": ["symbol", "kind"],
    }
    for name, expected_names in private_structs.items():
        fields, field_error = _f0_struct_fields(source, name)
        if field_error:
            errors.append(field_error)
            continue
        assert fields is not None
        if [field for _, field in fields] != expected_names:
            errors.append(f"IR identity {name} field inventory drifted: {fields!r}")
        if any(is_public for is_public, _ in fields):
            errors.append(f"IR identity {name} exposes forgeable public fields")

    required_internal_carriers = (
        "enum PathOwnerValue", "SymbolOwnerValue(SymbolRef)",
        "ModuleBodyOwnerValue(ModuleBodyRef)", "enum SlotRefValue",
        "SourceSlotValue {", "SyntheticSlotValue(PathRef)",
        "enum CalleeRefValue", "NamedCalleeValue(SymbolRef)",
        "LocalCalleeValue(SlotRef)", "DynamicCalleeValue(PathRef)",
    )
    for token in required_internal_carriers:
        if token not in source:
            errors.append(f"IR identity F0 misses private carrier {token!r}")
    for accessor in (
            "pub fn symbol_ref_origin_module_key(",
            "pub fn symbol_ref_namespace_kind(",
            "pub fn symbol_ref_canonical_payload(",
            "pub fn symbol_ref_declaration_site_path(",
            "pub fn path_owner_ref_symbol(",
            "pub fn path_owner_ref_module_body(",
            "pub fn path_ref_owner(",
            "pub fn path_ref_normalized_child_path(",
            "pub fn path_ref_role(",
            "pub fn slot_ref_source_origin_module_key(",
            "pub fn slot_ref_source_domain(",
            "pub fn slot_ref_source_def_id(",
            "pub fn slot_ref_synthetic_path(",
            "pub fn callee_ref_named_symbol(",
            "pub fn callee_ref_local_slot(",
            "pub fn callee_ref_dynamic_path(",
            "pub fn global_nominal_ref_symbol(",
            "pub fn global_nominal_ref_kind("):
        if accessor not in source:
            errors.append(f"IR identity F0 misses accessor {accessor!r}")

    symbol_body = _f0_require_function_tokens(source, "symbol_ref_same", (
        "left.origin_module_key == right.origin_module_key",
        "namespace_kind_same(left.namespace_kind, right.namespace_kind)",
        "left.canonical_payload == right.canonical_payload",
        "left.declaration_site_path == right.declaration_site_path",
    ), errors)
    _f0_require_function_tokens(source, "module_body_ref_same", (
        "left.origin_module_key == right.origin_module_key",
        "left.declaration_site_path == right.declaration_site_path",
    ), errors)
    _f0_require_function_tokens(source, "path_ref_same", (
        "path_owner_ref_same(left.owner, right.owner)",
        "string_list_same(",
        "left.normalized_child_path, right.normalized_child_path",
        "path_role_same(left.role, right.role)",
    ), errors)
    _f0_require_function_tokens(source, "slot_ref_same", (
        "am == bm", "slot_domain_same(ad, bd)", "ai == bi",
        "path_ref_same(a, b)", "_ => false",
    ), errors)
    _f0_require_function_tokens(source, "callee_ref_same", (
        "NamedCalleeValue", "symbol_ref_same(a, b)",
        "LocalCalleeValue", "slot_ref_same(a, b)",
        "DynamicCalleeValue", "path_ref_same(a, b)", "_ => false",
    ), errors)
    _f0_require_function_tokens(source, "global_nominal_ref_same", (
        "symbol_ref_same(left.symbol, right.symbol)",
        "nominal_kind_same(left.kind, right.kind)",
    ), errors)

    constructor_contracts = {
        "make_symbol_ref": (
            'origin_module_key == ""', 'canonical_payload == ""',
            'declaration_site_path == ""', "panic(",
            "namespace_kind_from_tag(",
            "namespace_kind_tag(namespace_kind)"),
        "make_module_body_ref": (
            'origin_module_key == ""', 'declaration_site_path == ""', "panic("),
        "make_path_ref": (
            "validate_normalized_child_path(normalized_child_path)",
            "path_role_from_tag(path_role_tag(role))",
            "normalized_child_path: copy_string_list(normalized_child_path)"),
        "make_source_slot_ref": (
            'origin_module_key == ""',
            "slot_domain_from_tag(slot_domain_tag(domain))",
            "slot_domain_is_lexical(checked_domain)", "def_id < 0",
            "def_id >= 0", "panic("),
        "make_global_nominal_ref": (
            "if !namespace_kind_same(\n"
            "            symbol_ref_namespace_kind(symbol), namespace_nominal())",
        ),
        "require_same_slot": ("if !slot_ref_same(left, right)", "panic("),
    }
    for function_name, tokens in constructor_contracts.items():
        _f0_require_function_tokens(source, function_name, tokens, errors)

    observed_fields = {
        field for field, token in {
            "origin_module_key":
                "left.origin_module_key == right.origin_module_key",
            "namespace_kind":
                "namespace_kind_same(left.namespace_kind, right.namespace_kind)",
            "canonical_payload":
                "left.canonical_payload == right.canonical_payload",
            "declaration_site_path":
                "left.declaration_site_path == right.declaration_site_path",
        }.items() if token in symbol_body
    }
    left = {
        "origin_module_key": "module-a", "namespace_kind": 0,
        "canonical_payload": "shared-name", "declaration_site_path": "decl/0"}
    right = dict(left)
    right["origin_module_key"] = "module-b"
    if all(left[field] == right[field] for field in observed_fields):
        errors.append("SymbolRef accepts same spelling from a different module")
    return errors


def resource_lattice_f0_contract_errors(source: str) -> List[str]:
    errors: List[str] = []
    masked = mask_ring_strings_and_comments(source)
    if re.search(r"(?m)^\s*use\s+", masked):
        errors.append("resource lattice F0 imports another compiler module")
    for forbidden in (
        "SymbolRef", "PathRef", "SlotRef", "CalleeRef", "GlobalNominalRef",
        "IdentityManifest", "ModelStage", "NormalizedResourceModel",
        "FinalFrozenResourceModel", "PlannedResourceModel",
        "VerifiedResourceModel", "OwnershipMetadata", "FnMeta", "HExpr",
        "resource_model_plan", "ResourceCertificate",
    ):
        if forbidden in masked:
            errors.append(f"resource lattice F0 gained forbidden authority {forbidden!r}")

    for name, expected_names in {
        "TransferDemand": ["mode", "force"],
        "LogicalOwnershipShape": ["direct_drop", "may_unique", "param_deps"],
        "PhysicalRcShape": [
            "physical_rc", "boxing", "drop_glue", "foreign_containment",
            "param_deps"],
    }.items():
        fields, field_error = _f0_struct_fields(source, name)
        if field_error:
            errors.append(field_error)
            continue
        assert fields is not None
        if [field for _, field in fields] != expected_names:
            errors.append(f"resource lattice {name} field inventory drifted")
        if any(is_public for is_public, _ in fields):
            errors.append(f"resource lattice {name} exposes forgeable public fields")

    param_table, param_table_error = _f0_int_list(source, "PARAM_MODE_JOIN_TAGS")
    param_ranks, param_rank_error = _f0_int_list(source, "PARAM_MODE_RANKS")
    if param_table_error:
        errors.append(param_table_error)
    if param_rank_error:
        errors.append(param_rank_error)
    expected_param_table = [max(left, right) for left in range(4) for right in range(4)]
    if param_table is not None and param_ranks is not None:
        errors.extend(_f0_lattice_errors(
            "ParamMode", param_table, param_ranks, 4))
        if param_table != expected_param_table:
            errors.append("ParamMode is not the strict Bottom<Borrow<MutBorrow<Own chain")
        if param_ranks != [0, 1, 2, 3]:
            errors.append("ParamMode ranks drifted")

    _f0_require_function_tokens(source, "make_transfer_demand", (
        "param_mode_from_tag(param_mode_tag(mode))",
        "if force && !param_mode_same(checked_mode, param_mode_own())",
        "panic(",
    ), errors)
    _f0_require_function_tokens(source, "transfer_demand_join", (
        "let joined_mode = param_mode_join(left.mode, right.mode)",
        "left.force || right.force", "make_transfer_demand(",
        "joined_mode, left.force || right.force",
    ), errors)
    _f0_require_function_tokens(source, "transfer_demand_same", (
        "param_mode_same(left.mode, right.mode)",
        "left.force == right.force",
    ), errors)
    _f0_require_function_tokens(source, "transfer_demand_leq", (
        "transfer_demand_same(transfer_demand_join(left, right), right)",
    ), errors)
    _f0_require_function_tokens(source, "transfer_demand_rank", (
        "if value.force { 1 } else { 0 }",
        "param_mode_rank(value.mode) + force_rank",
    ), errors)

    transfer_states = [
        (0, False), (1, False), (2, False),
        (3, False), (3, True)]

    def transfer_join(
        left: Tuple[int, bool], right: Tuple[int, bool],
    ) -> Tuple[int, bool]:
        mode = max(left[0], right[0])
        return mode, left[1] or right[1]

    transfer_ranks = {
        state: state[0] + (1 if state[1] else 0)
        for state in transfer_states
    }
    for left in transfer_states:
        if transfer_join(left, left) != left:
            errors.append(f"TransferDemand join is not idempotent at {left!r}")
        for right in transfer_states:
            joined = transfer_join(left, right)
            if joined not in transfer_ranks:
                errors.append(f"TransferDemand join is not total at {left!r},{right!r}")
                continue
            if joined != transfer_join(right, left):
                errors.append(f"TransferDemand join is not commutative at {left!r},{right!r}")
            if transfer_ranks[joined] < transfer_ranks[left] or (
                    transfer_ranks[joined] < transfer_ranks[right]):
                errors.append(f"TransferDemand rank decreases at {left!r},{right!r}")
            for third in transfer_states:
                if transfer_join(joined, third) != transfer_join(
                        left, transfer_join(right, third)):
                    errors.append(
                        f"TransferDemand join is not associative at "
                        f"{left!r},{right!r},{third!r}")

    bool_join_body = _f0_require_function_tokens(source, "bool_list_join", (
        "if left.len() != right.len()", "result.push(a || b)",
    ), errors)
    logical_body = _f0_require_function_tokens(
        source, "logical_ownership_shape_join", (
            "make_logical_ownership_shape(",
            "left.direct_drop || right.direct_drop",
            "left.may_unique || right.may_unique",
            "bool_list_join(left.param_deps, right.param_deps)"), errors)
    _f0_require_function_tokens(source, "make_logical_ownership_shape", (
        "if direct_drop && !may_unique", "panic(",
        "param_deps: copy_bool_list(param_deps)",
    ), errors)
    physical_body = _f0_require_function_tokens(
        source, "physical_rc_shape_join", (
            "make_physical_rc_shape(",
            "left.physical_rc || right.physical_rc",
            "left.boxing || right.boxing",
            "left.drop_glue || right.drop_glue",
            "left.foreign_containment || right.foreign_containment",
            "bool_list_join(left.param_deps, right.param_deps)"), errors)
    _f0_require_function_tokens(source, "make_physical_rc_shape", (
        "param_deps: copy_bool_list(param_deps)",
    ), errors)
    if not bool_join_body:
        errors.append("resource shape list join authority is missing")
    if any(token in logical_body for token in (
            "physical_rc", "boxing", "drop_glue", "foreign_containment")):
        errors.append("logical ownership shape reads physical RC state")
    if "direct_drop" in physical_body or "may_unique" in physical_body:
        errors.append("physical RC shape reads logical ownership state")

    slot_table, slot_table_error = _f0_int_list(source, "SLOT_FLOW_JOIN_TAGS")
    slot_ranks, slot_rank_error = _f0_int_list(source, "SLOT_FLOW_RANKS")
    for error in (slot_table_error, slot_rank_error):
        if error:
            errors.append(error)
    expected_slot_table = [
        0, 1, 2, 3, 4,
        1, 1, 4, 4, 4,
        2, 4, 2, 4, 4,
        3, 4, 4, 3, 4,
        4, 4, 4, 4, 4,
    ]
    if slot_table is not None and slot_ranks is not None:
        errors.extend(_f0_lattice_errors(
            "SlotFlow", slot_table, slot_ranks, 5))
        if slot_table != expected_slot_table:
            errors.append("SlotFlow Unreachable/reachable join table drifted")
        if slot_ranks != [0, 1, 1, 1, 2]:
            errors.append("SlotFlow ranks drifted")
    return errors


def _f0_semantic_mutation_errors(
    identity_source: str, resource_source: str,
) -> Tuple[List[str], int]:
    errors: List[str] = []
    count = 0
    identity_mutations = (
        ("Symbol module", "symbol_ref_same",
         "left.origin_module_key == right.origin_module_key", "true"),
        ("Symbol namespace", "symbol_ref_same",
         "namespace_kind_same(left.namespace_kind, right.namespace_kind)", "true"),
        ("Symbol payload", "symbol_ref_same",
         "left.canonical_payload == right.canonical_payload", "true"),
        ("Symbol declaration site", "symbol_ref_same",
         "left.declaration_site_path == right.declaration_site_path", "true"),
        ("module-body module", "module_body_ref_same",
         "left.origin_module_key == right.origin_module_key", "true"),
        ("module-body site", "module_body_ref_same",
         "left.declaration_site_path == right.declaration_site_path", "true"),
        ("path owner", "path_ref_same",
         "path_owner_ref_same(left.owner, right.owner)", "true"),
        ("path child", "path_ref_same",
         "string_list_same(\n            left.normalized_child_path, "
         "right.normalized_child_path)", "true"),
        ("path role", "path_ref_same",
         "path_role_same(left.role, right.role)", "true"),
        ("slot module", "slot_ref_same", "am == bm", "true"),
        ("slot domain", "slot_ref_same", "slot_domain_same(ad, bd)", "true"),
        ("slot DefId", "slot_ref_same", "ai == bi", "true"),
        ("slot synthetic path", "slot_ref_same",
         "path_ref_same(a, b)", "true"),
        ("named callee", "callee_ref_same", "symbol_ref_same(a, b)", "true"),
        ("local callee", "callee_ref_same", "slot_ref_same(a, b)", "true"),
        ("global nominal kind", "global_nominal_ref_same",
         "nominal_kind_same(left.kind, right.kind)", "true"),
        ("incomplete Symbol constructor", "make_symbol_ref",
         "if origin_module_key == \"\" || canonical_payload == \"\" ||\n"
         "       declaration_site_path == \"\"", "if false"),
        ("incomplete module-body constructor", "make_module_body_ref",
         "if origin_module_key == \"\" || declaration_site_path == \"\"",
         "if false"),
        ("unnormalized path constructor", "make_path_ref",
         "validate_normalized_child_path(normalized_child_path)",
         "let _ = normalized_child_path"),
        ("path constructor aliases input", "make_path_ref",
         "normalized_child_path: copy_string_list(normalized_child_path)",
         "normalized_child_path: normalized_child_path"),
        ("source slot module", "make_source_slot_ref",
         "if origin_module_key == \"\"", "if false"),
        ("source slot domain", "make_source_slot_ref",
         "if slot_domain_is_lexical(checked_domain)", "if false"),
        ("same-slot fail closed", "require_same_slot",
         "if !slot_ref_same(left, right)", "if false"),
    )
    for label, function_name, anchor, replacement in identity_mutations:
        count += 1
        mutated, mutation_error = _f0_mutate_function_once(
            identity_source, function_name, anchor, replacement)
        if mutation_error:
            errors.append(f"F0 semantic mutation {label}: {mutation_error}")
        elif not ir_identity_f0_contract_errors(mutated or ""):
            errors.append(f"F0 semantic mutation escaped: {label}")

    nominal_namespace_relation = (
        "if !namespace_kind_same(\n"
        "            symbol_ref_namespace_kind(symbol), namespace_nominal())")
    expected_nominal_finding = (
        "F0 make_global_nominal_ref misses relation "
        f"{nominal_namespace_relation!r}")
    for label, replacement in (
            ("GlobalNominal namespace check deleted", "if false"),
            ("GlobalNominal accepts value namespace",
             nominal_namespace_relation.replace(
                 "namespace_nominal()", "namespace_value()"))):
        count += 1
        mutated, mutation_error = _f0_mutate_function_once(
            identity_source, "make_global_nominal_ref",
            nominal_namespace_relation, replacement)
        if mutation_error:
            errors.append(f"F0 semantic mutation {label}: {mutation_error}")
            continue
        findings = ir_identity_f0_contract_errors(mutated or "")
        if findings != [expected_nominal_finding]:
            errors.append(
                f"F0 semantic mutation {label} findings were {findings!r}, "
                f"expected only {expected_nominal_finding!r}")

    resource_mutations = (
        ("FORCE invalid pair", "make_transfer_demand",
         "if force && !param_mode_same(checked_mode, param_mode_own())",
         "if false"),
        ("FORCE join", "transfer_demand_join",
         "left.force || right.force", "left.force"),
        ("FORCE equality", "transfer_demand_same",
         "left.force == right.force", "true"),
        ("FORCE order", "transfer_demand_leq",
         "transfer_demand_same(transfer_demand_join(left, right), right)",
         "param_mode_leq(left.mode, right.mode)"),
        ("FORCE rank", "transfer_demand_rank",
         "if value.force { 1 } else { 0 }", "0"),
        ("shape arity", "bool_list_join",
         "if left.len() != right.len()", "if false"),
        ("logical direct-drop invariant", "make_logical_ownership_shape",
         "if direct_drop && !may_unique", "if false"),
        ("logical dependency alias", "make_logical_ownership_shape",
         "param_deps: copy_bool_list(param_deps)",
         "param_deps: param_deps"),
        ("physical dependency alias", "make_physical_rc_shape",
         "param_deps: copy_bool_list(param_deps)",
         "param_deps: param_deps"),
    )
    for label, function_name, anchor, replacement in resource_mutations:
        count += 1
        mutated, mutation_error = _f0_mutate_function_once(
            resource_source, function_name, anchor, replacement)
        if mutation_error:
            errors.append(f"F0 semantic mutation {label}: {mutation_error}")
        elif not resource_lattice_f0_contract_errors(mutated or ""):
            errors.append(f"F0 semantic mutation escaped: {label}")

    cross_axis_mutations = (
        ("logical consumes physical axis",
         "left: LogicalOwnershipShape, right: LogicalOwnershipShape\n"
         ") -> LogicalOwnershipShape",
         "left: LogicalOwnershipShape, right: LogicalOwnershipShape,\n"
         "    physical: PhysicalRcShape\n) -> LogicalOwnershipShape",
         "left.may_unique || right.may_unique",
         "left.may_unique || right.may_unique || physical.physical_rc"),
        ("physical consumes logical axis",
         "left: PhysicalRcShape, right: PhysicalRcShape\n"
         ") -> PhysicalRcShape",
         "left: PhysicalRcShape, right: PhysicalRcShape,\n"
         "    logical: LogicalOwnershipShape\n) -> PhysicalRcShape",
         "left.physical_rc || right.physical_rc",
         "left.physical_rc || right.physical_rc || logical.may_unique"),
    )
    for label, signature, new_signature, anchor, replacement in (
            cross_axis_mutations):
        count += 1
        if resource_source.count(signature) != 1 or resource_source.count(anchor) < 1:
            errors.append(f"F0 semantic mutation {label}: anchor missing")
            continue
        mutated = resource_source.replace(signature, new_signature, 1)
        mutated = mutated.replace(anchor, replacement, 1)
        if not resource_lattice_f0_contract_errors(mutated):
            errors.append(f"F0 semantic mutation escaped: {label}")

    int_mutations = (
        ("Param Borrow/MutBorrow chain", "PARAM_MODE_JOIN_TAGS", 6, 1),
        ("Param Borrow/Own chain", "PARAM_MODE_JOIN_TAGS", 7, 2),
        ("Param rank chain", "PARAM_MODE_RANKS", 2, 1),
        ("Unreachable join", "SLOT_FLOW_JOIN_TAGS", 2, 4),
        ("reachable distinct join", "SLOT_FLOW_JOIN_TAGS", 7, 2),
    )
    for label, name, index, replacement in int_mutations:
        count += 1
        values, value_error = _f0_int_list(resource_source, name)
        if value_error:
            errors.append(f"F0 semantic mutation {label}: {value_error}")
            continue
        assert values is not None
        values[index] = replacement
        mutated, mutation_error = _f0_replace_const_list(
            resource_source, name, values)
        if mutation_error:
            errors.append(f"F0 semantic mutation {label}: {mutation_error}")
        elif not resource_lattice_f0_contract_errors(mutated or ""):
            errors.append(f"F0 semantic mutation escaped: {label}")

    count += 1
    stage_mutation = identity_source + (
        "\npub struct IdentityManifest { stage_hash: Str }\n"
        "pub struct ModelStage { tag: Int }\n")
    if not ir_identity_f0_contract_errors(stage_mutation):
        errors.append("F0 semantic mutation escaped: parallel stage API")
    if count != F0_SEMANTIC_MUTATION_COUNT:
        errors.append(
            f"F0 semantic mutation count was {count}, "
            f"expected {F0_SEMANTIC_MUTATION_COUNT}")
    return errors, count


def _f0_scope_guard_errors(
    identity_source: str, resource_source: str,
) -> Tuple[List[str], int]:
    errors: List[str] = []
    guards = (
        ("identity imports checker", "identity", "\nuse checker::{check}\n"),
        ("identity counter", "identity",
         "\nstruct IdentityCounter { next_identity: Int }\n"),
        ("identity name fallback", "identity",
         "\nfn identity_name_fallback(value: Str) -> Str { value }\n"),
        ("identity hash", "identity",
         "\nfn hash_identity(value: Str) -> Str { value }\n"),
        ("resource imports Perceus", "resource",
         "\nuse perceus::{perceus_transform}\n"),
        ("resource planner", "resource", "\nfn resource_model_plan() {}\n"),
        ("resource stores HIR", "resource",
         "\nstruct StoredTree { value: HExpr }\n"),
        ("resource certificate", "resource",
         "\nstruct ResourceCertificate { rank: Int }\n"),
        ("premature projection path", "identity",
         "\nstruct ProjectionPath { steps: List<Str> }\n"),
    )
    count = 0
    for label, target, suffix in guards:
        count += 1
        if target == "identity":
            findings = ir_identity_f0_contract_errors(identity_source + suffix)
        else:
            findings = resource_lattice_f0_contract_errors(
                resource_source + suffix)
        if not findings:
            errors.append(f"F0 scope guard escaped: {label}")
    if count != F0_SCOPE_GUARD_COUNT:
        errors.append(
            f"F0 scope guard count was {count}, expected {F0_SCOPE_GUARD_COUNT}")
    return errors, count


def resource_model_f0_source_errors() -> List[str]:
    errors: List[str] = []
    try:
        identity_source = IR_IDENTITY_F0_PATH.read_text(encoding="utf-8")
        resource_source = RESOURCE_MODEL_F0_PATH.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read F0 compiler sources: {exc}"]
    errors.extend(ir_identity_f0_contract_errors(identity_source))
    errors.extend(resource_lattice_f0_contract_errors(resource_source))
    if errors:
        return errors
    semantic_errors, _ = _f0_semantic_mutation_errors(
        identity_source, resource_source)
    guard_errors, _ = _f0_scope_guard_errors(identity_source, resource_source)
    errors.extend(semantic_errors)
    errors.extend(guard_errors)
    return errors


def resource_model_f0_compile_errors(ring_exe: str) -> List[str]:
    errors: List[str] = []
    compiler = Path(ring_exe)
    before = _sha256_file(compiler)
    environment = dict(_controlled_environment(ring_exe))
    for source_path in (IR_IDENTITY_F0_PATH, RESOURCE_MODEL_F0_PATH):
        completed = subprocess.run(
            [ring_exe, "check", str(source_path)],
            cwd=REPO, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="strict", check=False,
            timeout=120,
        )
        if completed.returncode != 0:
            errors.append(
                f"pinned Ring check failed for {display_path(source_path)}: "
                f"exit={completed.returncode} stdout={completed.stdout!r} "
                f"stderr={completed.stderr!r}")
        elif completed.stdout.strip() != "OK" or completed.stderr:
            errors.append(
                f"pinned Ring check output drifted for "
                f"{display_path(source_path)}: stdout={completed.stdout!r} "
                f"stderr={completed.stderr!r}")
    if _sha256_file(compiler) != before:
        errors.append("pinned Ring compiler changed across F0 checks")
    return errors


IR_INVENTORY_F1_PATH = REPO / "compiler" / "ir_inventory.ring"
F1_EXECUTABLE_KIND_COUNT = 19
F1_BINDER_KIND_COUNT = 25
F1_SEMANTIC_MUTATION_COUNT = 72
F1_SCOPE_GUARD_COUNT = 13

F2_U1A_RESOLVER_PATH = REPO / "compiler" / "resolver.ring"
F2_U1A_INFER_CTX_PATH = REPO / "compiler" / "infer_ctx.ring"
F2_U1A_SOURCE_CONTRACT_MUTATION_COUNT = 55
F2_U1A_SCOPE_GUARD_COUNT = 8
F2_U1B_SOURCE_CONTRACT_MUTATION_COUNT = 20
F2_U1C0_SOURCE_CONTRACT_MUTATION_COUNT = 35
F2_IMPL_EXPORT_CLOSURE_MUTATION_COUNT = 36

F1_EXECUTABLE_KINDS = (
    ("fn", "EXECUTABLE_FN"),
    ("impl_method", "EXECUTABLE_IMPL_METHOD"),
    ("trait_default", "EXECUTABLE_TRAIT_DEFAULT"),
    ("test", "EXECUTABLE_TEST"),
    ("const_initializer", "EXECUTABLE_CONST_INITIALIZER"),
    ("module_body", "EXECUTABLE_MODULE_BODY"),
    ("lambda", "EXECUTABLE_LAMBDA"),
    ("handler", "EXECUTABLE_HANDLER"),
    ("default_specialization", "EXECUTABLE_DEFAULT_SPECIALIZATION"),
    ("derived_impl", "EXECUTABLE_DERIVED_IMPL"),
    ("dict_helper", "EXECUTABLE_DICT_HELPER"),
    ("const_getter", "EXECUTABLE_CONST_GETTER"),
    ("drop_glue", "EXECUTABLE_DROP_GLUE"),
    ("bodyless_trait_member", "EXECUTABLE_BODYLESS_TRAIT_MEMBER"),
    ("bodyless_effect_operation", "EXECUTABLE_BODYLESS_EFFECT_OPERATION"),
    ("bodyless_interface_member", "EXECUTABLE_BODYLESS_INTERFACE_MEMBER"),
    ("extern_fn", "EXECUTABLE_EXTERN_FN"),
    ("extern_bridge", "EXECUTABLE_EXTERN_BRIDGE"),
    ("builtin_intrinsic", "EXECUTABLE_BUILTIN_INTRINSIC"),
)

F1_BINDER_KINDS = (
    ("source_param", "BINDER_SOURCE_PARAM"),
    ("let", "BINDER_LET"),
    ("var", "BINDER_VAR"),
    ("for", "BINDER_FOR"),
    ("destructure", "BINDER_DESTRUCTURE"),
    ("match_pattern", "BINDER_MATCH_PATTERN"),
    ("if_let_pattern", "BINDER_IF_LET_PATTERN"),
    ("catch_pattern", "BINDER_CATCH_PATTERN"),
    ("lambda_param", "BINDER_LAMBDA_PARAM"),
    ("handler_param", "BINDER_HANDLER_PARAM"),
    ("handler_resume", "BINDER_HANDLER_RESUME"),
    ("lambda_capture", "BINDER_LAMBDA_CAPTURE"),
    ("dictionary_evidence_local", "BINDER_DICTIONARY_EVIDENCE_LOCAL"),
    ("generated_synthetic_parameter", "BINDER_GENERATED_SYNTHETIC_PARAMETER"),
    ("lambda_value", "BINDER_LAMBDA_VALUE"),
    ("call_result", "BINDER_CALL_RESULT"),
    ("pre_anf", "BINDER_PRE_ANF"),
    ("pattern_projection", "BINDER_PATTERN_PROJECTION"),
    ("scope_result", "BINDER_SCOPE_RESULT"),
    ("control_result", "BINDER_CONTROL_RESULT"),
    ("assign_temp", "BINDER_ASSIGN_TEMP"),
    ("effect_ctx_param", "BINDER_EFFECT_CTX_PARAM"),
    ("effect_ctx_local", "BINDER_EFFECT_CTX_LOCAL"),
    ("effect_ctx_parent_capture", "BINDER_EFFECT_CTX_PARENT_CAPTURE"),
    ("dictionary_evidence_param", "BINDER_DICTIONARY_EVIDENCE_PARAM"),
)


def _f1_require_function_tokens(
    source: str, function_name: str, tokens: Tuple[str, ...],
    errors: List[str],
) -> str:
    body, body_error = _f0_function_body(source, function_name)
    if body_error:
        errors.append(body_error.replace("F0 function", "F1 function"))
        return ""
    assert body is not None
    for token in tokens:
        if token not in body:
            errors.append(f"F1 {function_name} misses relation {token!r}")
    return body


def ir_inventory_f1_contract_errors(source: str) -> List[str]:
    errors: List[str] = []
    masked = mask_ring_strings_and_comments(source)
    imports = re.findall(r"(?m)^\s*use\s+([A-Za-z_][A-Za-z0-9_]*)", masked)
    if imports != ["ir_identity"]:
        errors.append(f"F1 import authority drifted: {imports!r}")
    for forbidden in (
        "resolver", "checker", "codegen", "perceus",
        "OwnershipMetadata", "FnMeta", "HExpr", "HDecl", "Type::FnType",
        "IdentityCounter", "next_identity", "fresh_identity", "name_fallback",
        "display_name", "c_symbol", "FlowIrFreezeFacts", "node_count",
        "edge_count", "region_count", "resource_op_count",
        "binder_slot_set_same", "ResourcePlanner", "ResourceCertificate",
        "RcIR", "AbiIR", "CONTRACT_INTRINSIC", "Other", "Unknown",
    ):
        if forbidden in masked:
            errors.append(f"F1 gained forbidden authority {forbidden!r}")
    if re.search(r"(?m)^\s*(?:pub\s+)?(?:name|span|display|c_name)\s*:", masked):
        errors.append("F1 identity stores a raw name/span/display/C field")
    if re.search(r"\b(?:Clone|Take|Drop|Cleanup)\b", masked):
        errors.append("F1 gained forbidden resource operation")
    if ".sort" in masked or "sort_by" in masked:
        errors.append("F1 input order became identity through sorting")
    for name, expected in {
        "ExecutableRef": ["value"],
        "ExecutableParentRef": ["value"],
        "ExecutableKind": ["tag"],
        "ExecutableContractMode": ["tag"],
        "ExecutableContract": ["value"],
        "ExecutableEntry": ["reference", "parent", "kind", "contract"],
        "ExecutableInventory": ["entries"],
        "BinderKind": ["tag"],
        "BinderEntry": ["slot", "owner", "kind", "site"],
        "BinderManifest": ["owner", "entries"],
        "IrInventoryClosure": ["inventory", "manifests"],
    }.items():
        fields, field_error = _f0_struct_fields(source, name)
        if field_error:
            errors.append(field_error.replace("F0 struct", "F1 struct"))
            continue
        assert fields is not None
        if [field for _, field in fields] != expected:
            errors.append(f"F1 {name} private field inventory drifted")
        if any(is_public for is_public, _ in fields):
            errors.append(f"F1 {name} exposes forgeable public fields")

    for index, (function_suffix, constant_name) in enumerate(F1_EXECUTABLE_KINDS):
        const_token = f"const {constant_name}: Int = {index}"
        if const_token not in source:
            errors.append(f"F1 executable kind census misses {const_token!r}")
        function_name = f"executable_kind_{function_suffix}"
        _f1_require_function_tokens(source, function_name, (
            f"executable_kind_from_tag({constant_name})",
        ), errors)
    if len(F1_EXECUTABLE_KINDS) != F1_EXECUTABLE_KIND_COUNT:
        errors.append("F1 executable kind test census is incomplete")
    if "const EXECUTABLE_KIND_COUNT: Int = 19" not in source:
        errors.append("F1 executable kind count drifted")

    allowed_modes, allowed_error = _f0_int_list(
        source, "EXECUTABLE_KIND_ALLOWED_MODE_TAGS")
    ref_forms, ref_error = _f0_int_list(
        source, "EXECUTABLE_KIND_REF_FORM_TAGS")
    namespaces, namespace_error = _f0_int_list(
        source, "EXECUTABLE_KIND_NAMESPACE_TAGS")
    executable_roles, executable_role_error = _f0_int_list(
        source, "EXECUTABLE_KIND_PATH_ROLE_TAGS")
    parent_forms, parent_form_error = _f0_int_list(
        source, "EXECUTABLE_KIND_PARENT_FORM_TAGS")
    if allowed_error:
        errors.append(allowed_error)
    if ref_error:
        errors.append(ref_error)
    if namespace_error:
        errors.append(namespace_error)
    if executable_role_error:
        errors.append(executable_role_error)
    if parent_form_error:
        errors.append(parent_form_error)
    expected_modes = [
        0, 0, 0, 0, 0, 0, 0, 0, 0,
        2, 0, 2, 2,
        1, 1, 1, 1,
        2, 2,
    ]
    expected_ref_forms = [
        0, 0, 0, 1, 0, 1, 1, 1, 0,
        0, 1, 0, 0,
        0, 0, 0, 0,
        0, 0,
    ]
    expected_namespaces = [
        0, 4, 4, 5, 0, 5, 5, 5, 4,
        4, 5, 0, 4,
        4, 4, 4, 0,
        0, 0,
    ]
    expected_executable_roles = [
        7, 7, 7, 0, 7, 0, 1, 5, 7,
        7, 6, 7, 7,
        7, 7, 7, 7,
        7, 7,
    ]
    expected_parent_forms = [
        0, 0, 0, 0, 0, 0, 1, 1, 0,
        0, 2, 0, 0,
        0, 0, 0, 0,
        0, 0,
    ]
    if allowed_modes is not None and allowed_modes != expected_modes:
        errors.append("F1 executable kind/body-mode matrix drifted")
    if ref_forms is not None and ref_forms != expected_ref_forms:
        errors.append("F1 executable kind/ref-form matrix drifted")
    if namespaces is not None and namespaces != expected_namespaces:
        errors.append("F1 executable kind/namespace matrix drifted")
    if executable_roles is not None and (
            executable_roles != expected_executable_roles):
        errors.append("F1 executable kind/path-role matrix drifted")
    if parent_forms is not None and parent_forms != expected_parent_forms:
        errors.append("F1 executable kind/parent-form matrix drifted")
    if "pub fn executable_kind_drop_glue()" not in source:
        errors.append("F1 DropGlue executable kind is missing")

    _f1_require_function_tokens(source, "make_executable_entry", (
        "if !executable_kind_allows_mode(kind, mode)",
        "if expected_form != actual_form",
        "if !executable_kind_allows_parent_form(kind, parent)",
        "if !executable_parent_matches_reference(reference, parent)",
        "if !namespace_kind_same(",
        "if !path_role_same(\n                path_ref_role(path), "
        "executable_kind_expected_path_role(kind))",
        "if executable_kind_same(kind, executable_kind_module_body())",
        "if path_owner_ref_is_symbol(path_ref_owner(path))",
        "if !path_role_same(path_ref_role(body_path), path_role_child())",
        "!path_is_direct_child_of_executable(reference, body_path)",
        "!executable_ref_is_named(reference)",
    ), errors)
    _f1_require_function_tokens(source, "executable_parent_matches_reference", (
        "if executable_parent_is_module_body(parent)",
        "module_body_ref_same(",
        "path_ref_normalized_child_path(path).len() == 1",
        "path_is_direct_child_of_executable(\n            executable_parent, "
        "executable_ref_anonymous_path(reference))",
    ), errors)
    _f1_require_function_tokens(source, "path_is_direct_child_of_executable", (
        "path_ref_normalized_child_path(path).len() == 1",
        "child_path.len() == root_path.len() + 1",
        "string_path_has_prefix(child_path, root_path)",
    ), errors)
    _f1_require_function_tokens(source, "make_executable_inventory", (
        "if executable_ref_same(left.reference, right.reference)",
        'panic("IR inventory: duplicate executable reference")',
        "copy_executable_entries(entries)",
    ), errors)
    _f1_require_function_tokens(source, "executable_inventory_entries", (
        "copy_executable_entries(value.entries)",
    ), errors)
    for token in (
            "ConcreteBodyValue(PathRef)", "ContractOnlyValue",
            "make_concrete_body_contract", "make_contract_only"):
        if token not in source:
            errors.append(f"F1 two-mode body contract misses {token!r}")

    for index, (function_suffix, constant_name) in enumerate(F1_BINDER_KINDS):
        const_token = f"const {constant_name}: Int = {index}"
        if const_token not in source:
            errors.append(f"F1 binder kind census misses {const_token!r}")
        function_name = f"binder_kind_{function_suffix}"
        _f1_require_function_tokens(source, function_name, (
            f"binder_kind_from_tag({constant_name})",
        ), errors)
    if len(F1_BINDER_KINDS) != F1_BINDER_KIND_COUNT:
        errors.append("F1 binder kind test census is incomplete")
    if "const BINDER_KIND_COUNT: Int = 25" not in source:
        errors.append("F1 binder kind count drifted")
    binder_roles, binder_role_error = _f0_int_list(
        source, "BINDER_KIND_PATH_ROLE_TAGS")
    if binder_role_error:
        errors.append(binder_role_error)
    expected_binder_roles = [
        2, 0, 0, 0, 0, 0, 0, 0, 2, 5, 5,
        4, 0, 2, 1, 3, 6, 1, 3, 3, 6,
        2, 5, 4, 2,
    ]
    if binder_roles is not None and binder_roles != expected_binder_roles:
        errors.append("F1 binder kind/path-role matrix drifted")

    _f1_require_function_tokens(source, "make_source_binder_entry", (
        "if !binder_kind_is_source(kind)",
        "if !slot_ref_is_source(slot)",
        "slot_ref_source_def_id(slot) < 0",
        "slot_ref_source_domain(slot), slot_domain_lexical()",
        "slot_ref_source_origin_module_key(slot) !=",
        "executable_ref_origin_module_key(owner)",
        "path_owner_origin_module_key(path_ref_owner(site))",
        "!executable_ref_contains_path(owner, site)",
        "if !path_role_same(\n            path_ref_role(site), "
        "binder_kind_expected_path_role(kind))",
    ), errors)
    _f1_require_function_tokens(source, "make_synthetic_binder_entry", (
        "if binder_kind_is_source(kind)",
        "if slot_ref_is_source(slot)",
        "if !executable_ref_contains_path(owner, site)",
        "if !path_role_same(\n            path_ref_role(site), "
        "binder_kind_expected_path_role(kind))",
        "if !path_ref_same(slot_ref_synthetic_path(slot), site)",
    ), errors)
    _f1_require_function_tokens(source, "make_binder_manifest", (
        "if !executable_ref_same(left.owner, owner)",
        "if slot_ref_same(left.slot, right.slot)",
        "copy_binder_entries(entries)",
    ), errors)
    _f1_require_function_tokens(source, "binder_manifest_entries", (
        "copy_binder_entries(value.entries)",
    ), errors)
    _f1_require_function_tokens(source, "close_ir_inventory", (
        "if manifests.len() != inventory.entries.len()",
        "if manifests_have_duplicate_slot(manifests)",
        "if !executable_parent_is_registered(inventory, entry)",
        "if manifest_count_for_owner(manifests, entry.reference) != 1",
        "let manifest = manifest_for_owner(manifests, entry.reference)",
        "if !binder_site_has_nearest_registered_owner(inventory, binder)",
        "manifest.entries.len() != 0",
        "if !inventory_contains_ref(inventory, manifest.owner)",
        "make_executable_inventory(inventory.entries)",
        "copy_binder_manifests(manifests)",
    ), errors)
    _f1_require_function_tokens(source, "manifests_have_duplicate_slot", (
        "if slot_ref_same(existing, entry.slot) { return true }",
    ), errors)
    _f1_require_function_tokens(source, "executable_parent_is_registered", (
        "if executable_parent_is_module_body(entry.parent) { return true }",
        "let parent_ref = executable_parent_executable(entry.parent)",
        "executable_contract_mode_concrete_body()",
    ), errors)
    _f1_require_function_tokens(source, "binder_site_has_nearest_registered_owner", (
        "if !inventory_contains_ref(inventory, binder.owner)",
        "!executable_ref_contains_path(binder.owner, binder.site)",
        "executable_ref_depth(candidate.reference) > owner_depth",
    ), errors)
    _f1_require_function_tokens(source, "ir_inventory_closure_inventory", (
        "make_executable_inventory(value.inventory.entries)",
    ), errors)
    _f1_require_function_tokens(source, "ir_inventory_closure_manifests", (
        "copy_binder_manifests(value.manifests)",
    ), errors)
    return errors


def _f1_expected_relation_finding(function_name: str, token: str) -> str:
    return f"F1 {function_name} misses relation {token!r}"


def ir_inventory_f1_semantic_mutation_errors(source: str) -> Tuple[List[str], int]:
    errors: List[str] = []
    count = 0

    for index, (function_suffix, constant_name) in enumerate(F1_EXECUTABLE_KINDS):
        function_name = f"executable_kind_{function_suffix}"
        anchor = f"executable_kind_from_tag({constant_name})"
        replacement_constant = F1_EXECUTABLE_KINDS[(index + 1) % len(
            F1_EXECUTABLE_KINDS)][1]
        mutated, mutation_error = _f0_mutate_function_once(
            source, function_name, anchor,
            f"executable_kind_from_tag({replacement_constant})")
        count += 1
        if mutation_error:
            errors.append(f"F1 semantic mutation {function_suffix}: {mutation_error}")
            continue
        findings = ir_inventory_f1_contract_errors(mutated or "")
        expected = _f1_expected_relation_finding(function_name, anchor)
        if findings != [expected]:
            errors.append(
                f"F1 semantic mutation {function_suffix} findings were "
                f"{findings!r}, expected only {expected!r}")

    function_mutations = (
        ("duplicate executable", "make_executable_inventory",
         "if executable_ref_same(left.reference, right.reference)", "if false"),
        ("kind/body mode", "make_executable_entry",
         "if !executable_kind_allows_mode(kind, mode)", "if false"),
        ("kind/ref form", "make_executable_entry",
         "if expected_form != actual_form", "if false"),
        ("kind/parent form", "make_executable_entry",
         "if !executable_kind_allows_parent_form(kind, parent)", "if false"),
        ("kind/namespace", "make_executable_entry",
         "if !namespace_kind_same(", "if false && namespace_kind_same("),
        ("kind/path role", "make_executable_entry",
         "if !path_role_same(\n                path_ref_role(path), "
         "executable_kind_expected_path_role(kind))",
         "if false"),
        ("immediate parent", "make_executable_entry",
         "if !executable_parent_matches_reference(reference, parent)", "if false"),
        ("parent relation helper", "executable_parent_matches_reference",
         "path_is_direct_child_of_executable(\n            executable_parent, "
         "executable_ref_anonymous_path(reference))", "true"),
        ("module-body owner", "make_executable_entry",
         "if path_owner_ref_is_symbol(path_ref_owner(path))", "if false"),
        ("body path role", "make_executable_entry",
         "if !path_role_same(path_ref_role(body_path), path_role_child())",
         "if false"),
        ("body direct child", "make_executable_entry",
         "!path_is_direct_child_of_executable(reference, body_path)", "false"),
        ("body direct-child helper", "path_is_direct_child_of_executable",
         "child_path.len() == root_path.len() + 1", "child_path.len() > root_path.len()"),
        ("anonymous ContractOnly", "make_executable_entry",
         "!executable_ref_is_named(reference)", "false"),
        ("source binder kind", "make_source_binder_entry",
         "if !binder_kind_is_source(kind)", "if false"),
        ("source binder slot", "make_source_binder_entry",
         "if !slot_ref_is_source(slot)", "if false"),
        ("source binder DefId", "make_source_binder_entry",
         "slot_ref_source_def_id(slot) < 0", "false"),
        ("source binder domain", "make_source_binder_entry",
         "!slot_domain_same(\n            slot_ref_source_domain(slot), slot_domain_lexical())",
         "false"),
        ("source binder module", "make_source_binder_entry",
         "slot_ref_source_origin_module_key(slot) !=\n           executable_ref_origin_module_key(owner)",
         "false"),
        ("source binder site containment", "make_source_binder_entry",
         "!executable_ref_contains_path(owner, site)", "false"),
        ("source binder site role", "make_source_binder_entry",
         "if !path_role_same(\n            path_ref_role(site), "
         "binder_kind_expected_path_role(kind))", "if false"),
        ("source kind rejected", "make_synthetic_binder_entry",
         "if binder_kind_is_source(kind)", "if false"),
        ("source SlotRef rejected", "make_synthetic_binder_entry",
         "if slot_ref_is_source(slot)", "if false"),
        ("binder site containment", "make_synthetic_binder_entry",
         "if !executable_ref_contains_path(owner, site)", "if false"),
        ("binder site role", "make_synthetic_binder_entry",
         "if !path_role_same(\n            path_ref_role(site), "
         "binder_kind_expected_path_role(kind))", "if false"),
        ("synthetic binder site", "make_synthetic_binder_entry",
         "if !path_ref_same(slot_ref_synthetic_path(slot), site)", "if false"),
        ("manifest cross-owner", "make_binder_manifest",
         "if !executable_ref_same(left.owner, owner)", "if false"),
        ("manifest duplicate slot", "make_binder_manifest",
         "if slot_ref_same(left.slot, right.slot)", "if false"),
        ("closure census", "close_ir_inventory",
         "if manifests.len() != inventory.entries.len()", "if false"),
        ("global duplicate slot", "close_ir_inventory",
         "if manifests_have_duplicate_slot(manifests)", "if false"),
        ("global duplicate helper", "manifests_have_duplicate_slot",
         "if slot_ref_same(existing, entry.slot) { return true }", "if false {}"),
        ("parent registration", "close_ir_inventory",
         "if !executable_parent_is_registered(inventory, entry)",
         "if false"),
        ("parent registration helper", "executable_parent_is_registered",
         "executable_contract_mode_concrete_body()",
         "executable_contract_mode_contract_only()"),
        ("nearest binder owner", "close_ir_inventory",
         "if !binder_site_has_nearest_registered_owner(inventory, binder)",
         "if false"),
        ("nearest binder helper", "binder_site_has_nearest_registered_owner",
         "executable_ref_depth(candidate.reference) > owner_depth", "false"),
        ("missing manifest", "close_ir_inventory",
         "if manifest_count_for_owner(manifests, entry.reference) != 1",
         "if false"),
        ("ContractOnly binders", "close_ir_inventory",
         "manifest.entries.len() != 0", "false"),
        ("manifest owner absent", "close_ir_inventory",
         "if !inventory_contains_ref(inventory, manifest.owner)", "if false"),
    )
    for label, function_name, anchor, replacement in function_mutations:
        count += 1
        mutated, mutation_error = _f0_mutate_function_once(
            source, function_name, anchor, replacement)
        if mutation_error:
            errors.append(f"F1 semantic mutation {label}: {mutation_error}")
            continue
        findings = ir_inventory_f1_contract_errors(mutated or "")
        expected = _f1_expected_relation_finding(function_name, anchor)
        if findings != [expected]:
            errors.append(
                f"F1 semantic mutation {label} findings were {findings!r}, "
                f"expected only {expected!r}")

    table_mutations = (
        ("DropGlue body-mode", "EXECUTABLE_KIND_ALLOWED_MODE_TAGS", 13, 0,
         "F1 executable kind/body-mode matrix drifted"),
        ("dict-helper ref form", "EXECUTABLE_KIND_REF_FORM_TAGS", 11, 0,
         "F1 executable kind/ref-form matrix drifted"),
        ("Fn namespace", "EXECUTABLE_KIND_NAMESPACE_TAGS", 0, 5,
         "F1 executable kind/namespace matrix drifted"),
        ("handler executable role", "EXECUTABLE_KIND_PATH_ROLE_TAGS", 7, 1,
         "F1 executable kind/path-role matrix drifted"),
        ("lambda parent form", "EXECUTABLE_KIND_PARENT_FORM_TAGS", 6, 0,
         "F1 executable kind/parent-form matrix drifted"),
        ("lambda-capture role", "BINDER_KIND_PATH_ROLE_TAGS", 11, 1,
         "F1 binder kind/path-role matrix drifted"),
        ("source-param role", "BINDER_KIND_PATH_ROLE_TAGS", 0, 0,
         "F1 binder kind/path-role matrix drifted"),
        ("lambda-param role", "BINDER_KIND_PATH_ROLE_TAGS", 8, 0,
         "F1 binder kind/path-role matrix drifted"),
        ("handler-param role", "BINDER_KIND_PATH_ROLE_TAGS", 9, 0,
         "F1 binder kind/path-role matrix drifted"),
        ("handler-resume role", "BINDER_KIND_PATH_ROLE_TAGS", 10, 0,
         "F1 binder kind/path-role matrix drifted"),
        ("dictionary-local role", "BINDER_KIND_PATH_ROLE_TAGS", 12, 2,
         "F1 binder kind/path-role matrix drifted"),
        ("generated-param role", "BINDER_KIND_PATH_ROLE_TAGS", 13, 0,
         "F1 binder kind/path-role matrix drifted"),
        ("call-result role", "BINDER_KIND_PATH_ROLE_TAGS", 15, 6,
         "F1 binder kind/path-role matrix drifted"),
        ("handled-evidence-param role", "BINDER_KIND_PATH_ROLE_TAGS", 21, 0,
         "F1 binder kind/path-role matrix drifted"),
        ("handled-evidence-local role", "BINDER_KIND_PATH_ROLE_TAGS", 22, 0,
         "F1 binder kind/path-role matrix drifted"),
        ("handled-evidence-capture role", "BINDER_KIND_PATH_ROLE_TAGS", 23, 0,
         "F1 binder kind/path-role matrix drifted"),
    )
    for label, table_name, index, replacement, expected in table_mutations:
        count += 1
        values, value_error = _f0_int_list(source, table_name)
        if value_error:
            errors.append(f"F1 semantic mutation {label}: {value_error}")
            continue
        assert values is not None
        values[index] = replacement
        mutated, mutation_error = _f0_replace_const_list(
            source, table_name, values)
        if mutation_error:
            errors.append(f"F1 semantic mutation {label}: {mutation_error}")
            continue
        findings = ir_inventory_f1_contract_errors(mutated or "")
        if findings != [expected]:
            errors.append(
                f"F1 semantic mutation {label} findings were {findings!r}, "
                f"expected only {expected!r}")

    if count != F1_SEMANTIC_MUTATION_COUNT:
        errors.append(
            f"F1 semantic mutation count was {count}, "
            f"expected {F1_SEMANTIC_MUTATION_COUNT}")
    return errors, count


def ir_inventory_f1_scope_guard_errors(source: str) -> Tuple[List[str], int]:
    guards = (
        ("resolver import", "\nuse resolver::{resolve_namespace_plan}\n"),
        ("checker import", "\nuse checker::{check}\n"),
        ("codegen import", "\nuse codegen_c::{generate_c}\n"),
        ("Perceus import", "\nuse perceus::{perceus_transform}\n"),
        ("shared counter", "\nstruct IdentityCounter { next_identity: Int }\n"),
        ("name fallback", "\nfn name_fallback(value: Str) -> Str { value }\n"),
        ("legacy HIR scan", "\nstruct Legacy { value: HExpr }\n"),
        ("C symbol identity", "\nstruct CName { c_symbol: Str }\n"),
        ("fake structural counts", "\nstruct FakeFreeze { node_count: Int }\n"),
        ("premature binder equality", "\nfn binder_slot_set_same() {}\n"),
        ("third body mode", "\nconst CONTRACT_INTRINSIC: Int = 2\n"),
        ("resource census claim", "\nstruct Ops { resource_op_count: Int }\n"),
        ("resource operation", "\nstruct ResourceOp { op: Take }\n"),
    )
    errors: List[str] = []
    count = 0
    for label, suffix in guards:
        count += 1
        if not ir_inventory_f1_contract_errors(source + suffix):
            errors.append(f"F1 scope guard escaped: {label}")
    if count != F1_SCOPE_GUARD_COUNT:
        errors.append(
            f"F1 scope guard count was {count}, expected {F1_SCOPE_GUARD_COUNT}")
    return errors, count


def ir_inventory_f1_source_errors() -> List[str]:
    try:
        source = IR_INVENTORY_F1_PATH.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read {display_path(IR_INVENTORY_F1_PATH)}: {exc}"]
    errors = ir_inventory_f1_contract_errors(source)
    if errors:
        return errors
    semantic_errors, _ = ir_inventory_f1_semantic_mutation_errors(source)
    guard_errors, _ = ir_inventory_f1_scope_guard_errors(source)
    errors.extend(semantic_errors)
    errors.extend(guard_errors)
    return errors


LLM_WARNING_ENVELOPE_KEYS = frozenset(("version", "file", "diagnostics"))
LLM_WARNING_DIAGNOSTIC_KEYS = frozenset((
    "code", "severity", "message", "span", "context",
    "notes", "suggestions", "category",
))
LLM_WARNING_SPAN_KEYS = frozenset(("line", "col", "end_line", "end_col"))


def _reject_duplicate_json_keys(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def llm_warning_document_sequence(
    output: str,
) -> Tuple[Optional[List[Dict[str, Any]]], Optional[str]]:
    """Decode exact newline-separated formatter-v1 warning documents."""
    if not output:
        return None, "expected non-empty LLM warning document sequence"
    decoder = json.JSONDecoder(object_pairs_hook=_reject_duplicate_json_keys)
    documents: List[Any] = []
    offset = 0
    while offset < len(output):
        try:
            document, end = decoder.raw_decode(output, offset)
        except (json.JSONDecodeError, ValueError) as exc:
            return None, f"invalid LLM warning JSON document: {exc}"
        documents.append(document)
        if end == len(output) or output[end:end + 1] != "\n":
            return None, "each LLM warning document must end with one newline"
        offset = end + 1
        if offset == len(output):
            break

    flattened: List[Dict[str, Any]] = []
    unique_keys: set[Tuple[Any, ...]] = set()
    for document in documents:
        if not isinstance(document, dict) or (
                frozenset(document.keys()) != LLM_WARNING_ENVELOPE_KEYS):
            return None, "LLM warning envelope keys drifted"
        if document.get("version") != 1 or not isinstance(document.get("file"), str):
            return None, "LLM warning envelope version/file drifted"
        diagnostics = document.get("diagnostics")
        if not isinstance(diagnostics, list) or not diagnostics:
            return None, "LLM warning envelope has no diagnostics"
        for diagnostic in diagnostics:
            if not isinstance(diagnostic, dict) or (
                    frozenset(diagnostic.keys()) !=
                    LLM_WARNING_DIAGNOSTIC_KEYS):
                return None, "LLM warning diagnostic keys drifted"
            span = diagnostic.get("span")
            if not isinstance(span, dict) or (
                    frozenset(span.keys()) != LLM_WARNING_SPAN_KEYS):
                return None, "LLM warning span keys drifted"
            key = (
                document["file"], diagnostic.get("code"),
                span.get("line"), span.get("col"),
                span.get("end_line"), span.get("end_col"),
            )
            if key in unique_keys:
                return None, f"duplicate LLM warning diagnostic key {key!r}"
            unique_keys.add(key)
            flattened.append({
                "file": document["file"],
                "diagnostic": diagnostic,
            })
    return flattened, None


def llm_warning_contract_error(
    output: str, expected: Sequence[Mapping[str, Any]],
) -> Optional[str]:
    actual, error = llm_warning_document_sequence(output)
    if error is not None or actual is None:
        return error
    if actual != list(expected):
        return (
            "LLM warning sequence drifted: "
            f"expected={list(expected)!r} actual={actual!r}")
    return None


def _f1_run_ring_check(
    ring_exe: str, source_path: Path, environment: dict[str, str],
    timeout_seconds: int = 120,
    expected_warnings: Optional[Sequence[Mapping[str, Any]]] = None,
) -> Optional[str]:
    command = [ring_exe, "check", str(source_path)]
    if expected_warnings is not None:
        command.append("--error-format=llm")
    try:
        completed = subprocess.run(
            command, cwd=REPO, env=environment,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="strict",
            check=False, timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        return (
            f"pinned Ring check timed out for {source_path} after "
            f"{timeout_seconds}s")
    if completed.returncode != 0:
        return (
            f"pinned Ring check failed for {source_path}: "
            f"exit={completed.returncode} stdout={completed.stdout!r} "
            f"stderr={completed.stderr!r}")
    if completed.stdout != "OK\n":
        return (
            f"pinned Ring check output drifted for {source_path}: "
            f"stdout={completed.stdout!r} stderr={completed.stderr!r}")
    if expected_warnings is None:
        if completed.stderr:
            return (
                f"pinned Ring check output drifted for {source_path}: "
                f"stdout={completed.stdout!r} stderr={completed.stderr!r}")
    else:
        warning_error = llm_warning_contract_error(
            completed.stderr, expected_warnings)
        if warning_error is not None:
            return f"pinned Ring warning drift for {source_path}: {warning_error}"
    return None


def ir_inventory_f1_compile_errors(ring_exe: str) -> List[str]:
    errors: List[str] = []
    compiler = Path(ring_exe)
    compiler_before = _sha256_file(compiler)
    source = IR_INVENTORY_F1_PATH.read_text(encoding="utf-8")
    identity_source = IR_IDENTITY_F0_PATH.read_text(encoding="utf-8")
    environment = dict(_controlled_environment(ring_exe))

    original_error = _f1_run_ring_check(
        ring_exe, IR_INVENTORY_F1_PATH, environment)
    if original_error:
        errors.append(original_error)

    anchor = "executable_kind_from_tag(EXECUTABLE_DROP_GLUE)"
    mutated, mutation_error = _f0_mutate_function_once(
        source, "executable_kind_drop_glue", anchor,
        "executable_kind_from_tag(EXECUTABLE_DICT_HELPER)")
    if mutation_error:
        errors.append(f"F1 material mutation could not be built: {mutation_error}")
    else:
        assert mutated is not None
        expected = _f1_expected_relation_finding(
            "executable_kind_drop_glue", anchor)
        findings = ir_inventory_f1_contract_errors(mutated)
        if findings != [expected]:
            errors.append(
                f"F1 material mutation findings were {findings!r}, "
                f"expected only {expected!r}")
        with tempfile.TemporaryDirectory(prefix="ring_ir_inventory_f1_") as temp:
            compiler_dir = Path(temp) / "compiler"
            compiler_dir.mkdir(parents=False, exist_ok=False)
            identity_path = compiler_dir / "ir_identity.ring"
            inventory_path = compiler_dir / "ir_inventory.ring"
            identity_path.write_text(identity_source, encoding="utf-8", newline="\n")
            inventory_path.write_text(mutated, encoding="utf-8", newline="\n")
            mutation_check_error = _f1_run_ring_check(
                ring_exe, inventory_path, environment)
            if mutation_check_error:
                errors.append(mutation_check_error)
    if _sha256_file(compiler) != compiler_before:
        errors.append("pinned Ring compiler changed across F1 checks")
    return errors


CORE_HIR_C0_PATH = REPO / "compiler" / "core_hir.ring"
CORE_HIR_C0_MUTATION_COUNT = 29
CORE_HIR_C0_SCOPE_GUARD_COUNT = 3


def core_hir_c0_contract_errors(
    core_source: str, identity_source: str, inventory_source: str,
) -> List[str]:
    errors: List[str] = []
    core_masked = mask_ring_strings_and_comments(core_source)
    imports = re.findall(
        r"(?m)^\s*use\s+([A-Za-z_][A-Za-z0-9_]*)", core_masked)
    if imports != ["ir_identity", "ir_inventory"]:
        errors.append(f"C0 import authority drifted: {imports!r}")
    for forbidden in (
        "resource_model", "HProgram", "HDecl", "DerivedImpl",
        "FieldAction", "ImplEntry", "DictDispatchInfo", "ParamMode",
        "CallResourcePlan", "ResourcePlanner", "ResourceCertificate",
        "AbiIR", "FlowIR", "RcIR", "HExpr", "HStmt",
    ):
        if forbidden in core_masked:
            errors.append(f"C0 gained forbidden authority {forbidden!r}")
    if re.search(
            r"\b(?:ownership|borrow_mode|take_mode|cleanup_mode)\b",
            core_masked, re.IGNORECASE):
        errors.append("C0 gained an ownership-mode surface")
    if ".sort" in core_masked or "sort_by" in core_masked:
        errors.append("C0 body/inventory order was normalized by sorting")
    for forbidden in (
        "core_body_entry_body", "core_program_bodies",
        "validate_core_expr", "lower_hprogram",
    ):
        if forbidden in core_masked:
            errors.append(f"C0 exposed material-body authority {forbidden!r}")

    origin_fields, origin_error = _f0_struct_fields(
        identity_source, "OriginRef")
    if origin_error:
        errors.append(origin_error.replace("F0 struct", "C0 OriginRef struct"))
    elif origin_fields is not None:
        if [name for _, name in origin_fields] != ["value"]:
            errors.append("C0 OriginRef field inventory drifted")
        if any(is_public for is_public, _ in origin_fields):
            errors.append("C0 OriginRef exposes forgeable fields")
    for token in (
        "SymbolOriginValue(SymbolRef)", "PathOriginValue(PathRef)",
    ):
        if token not in identity_source:
            errors.append(f"C0 OriginRef form misses {token!r}")
    symbol_ctor, symbol_error = _f0_function_body(
        identity_source, "make_symbol_origin_ref")
    if symbol_error:
        errors.append(symbol_error)
    elif symbol_ctor is not None:
        if "SymbolOriginValue(value)" not in symbol_ctor:
            errors.append("C0 symbol OriginRef does not wrap exact input")
        if "make_symbol_ref(" in symbol_ctor:
            errors.append("C0 symbol OriginRef reconstructs SymbolRef")
    path_ctor, path_error = _f0_function_body(
        identity_source, "make_path_origin_ref")
    if path_error:
        errors.append(path_error)
    elif path_ctor is not None:
        if "PathOriginValue(value)" not in path_ctor:
            errors.append("C0 path OriginRef does not wrap exact input")
        if "make_path_ref(" in path_ctor:
            errors.append("C0 path OriginRef reconstructs PathRef")
    origin_same, origin_same_error = _f0_function_body(
        identity_source, "origin_ref_same")
    if origin_same_error:
        errors.append(origin_same_error)
    elif origin_same is not None:
        for token in (
            "symbol_ref_same(a, b)", "path_ref_same(a, b)",
            "_ => false",
        ):
            if token not in origin_same:
                errors.append(f"C0 OriginRef equality misses {token!r}")

    for struct_name, expected_fields in (
        ("CoreBodyEntry", ["reference", "origin", "body_anchor"]),
        ("CoreProgram", ["closure", "bodies"]),
    ):
        fields, field_error = _f0_struct_fields(core_source, struct_name)
        if field_error:
            errors.append(field_error.replace("F0 struct", f"C0 {struct_name} struct"))
            continue
        assert fields is not None
        if [name for _, name in fields] != expected_fields:
            errors.append(f"C0 {struct_name} field inventory drifted")
        if any(is_public for is_public, _ in fields):
            errors.append(f"C0 {struct_name} exposes forgeable fields")
    if "pub fn make_core_body_entry(" not in core_source or (
            "pub fn make_core_program(" not in core_source):
        errors.append("C0 smart constructor surface is incomplete")
    if re.search(
            r"pub\s+struct\s+CoreBodyEntry\s*\{\s*"
            r"reference\s*:\s*ExecutableRef\s*,\s*"
            r"origin\s*:\s*OriginRef\s*,\s*"
            r"body_anchor\s*:\s*PathRef\s*\}",
            core_masked) is None:
        errors.append("C0 body anchor is not an exact PathRef")

    body_ctor, body_ctor_error = _f0_function_body(
        core_source, "make_core_body_entry")
    if body_ctor_error:
        errors.append(body_ctor_error)
    elif body_ctor is not None and not all(token in body_ctor for token in (
            "reference: reference", "origin: origin",
            "body_anchor: body_anchor")):
        errors.append("C0 body-anchor constructor is incomplete")

    program_ctor, program_ctor_error = _f0_function_body(
        core_source, "make_core_program")
    if program_ctor_error:
        errors.append(program_ctor_error)
    elif program_ctor is not None:
        for token in (
            "close_ir_inventory(inventory, manifests)",
            "ir_inventory_closure_inventory(closure)",
            "validate_core_body_subsequence(bodies, closed_inventory)",
            "closure: closure", "bodies: copy_core_body_entries(bodies)",
        ):
            if token not in program_ctor:
                errors.append(f"C0 program constructor misses {token!r}")
    subsequence, subsequence_error = _f0_function_body(
        core_source, "validate_core_body_subsequence")
    if subsequence_error:
        errors.append(subsequence_error)
    elif subsequence is not None:
        for token in (
            "core_body_refs_are_unique(bodies)",
            "for entry in entries", "bodies.get(body_index)",
            "body.reference, executable_entry_reference(entry)",
            "body.body_anchor,",
            "executable_contract_body_path(contract)",
            "body_index = body_index + 1", "body_index != bodies.len()",
            "executable_contract_mode_concrete_body()",
            "executable_contract_mode_contract_only()",
        ):
            if token not in subsequence:
                errors.append(f"C0 body/inventory closure misses {token!r}")

    # Reuse the existing F1 authority for named ImplMethod SymbolRef form and
    # BinderManifest closure rather than duplicating those tables in C0.
    inventory_errors = ir_inventory_f1_contract_errors(inventory_source)
    if inventory_errors:
        errors.extend(f"C0 inherited inventory failure: {e}" for e in inventory_errors)
    return errors


def core_hir_c0_live_consumer_errors(
    compiler_sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    consumers: List[str] = []
    for name, source in compiler_sources.items():
        if name == "core_hir.ring":
            continue
        masked = mask_ring_strings_and_comments(source)
        if re.search(r"(?m)^\s*use\s+core_hir\b", masked) or (
                "core_hir::" in masked) or "CoreProgram" in masked:
            consumers.append(name)
    if consumers != ["builtins.ring"]:
        errors.append(
            f"C0 live consumer inventory drifted: {consumers!r}")

    builtins_source = compiler_sources.get("builtins.ring", "")
    shadow_body, shadow_error = _f0_function_body(
        builtins_source, "validate_builtin_method_core_shadow")
    if shadow_error:
        errors.append(shadow_error.replace("F0 function", "C0 consumer"))
    elif shadow_body is not None:
        for token in (
            "make_executable_entry(", "make_contract_only()",
            "make_binder_manifest(executable, [])",
            "make_core_program(", "core_program_body_count(program) != 0",
        ):
            if token not in shadow_body:
                errors.append(f"C0 live consumer misses {token!r}")

    checker_source = compiler_sources.get("checker.ring", "")
    load_body, load_error = _f0_function_body(
        checker_source, "load_prelude")
    if load_error:
        errors.append(load_error.replace("F0 function", "C0 consumer"))
    elif load_body is not None and (
            "validate_builtin_method_core_shadow(ctx.env)" not in load_body):
        errors.append("C0 shared checker consumer is missing")
    return errors


def core_hir_c0_mutation_errors(
    core_source: str, identity_source: str, inventory_source: str,
) -> List[str]:
    errors: List[str] = []
    mutations = (
        ("symbol origin rebuild", "identity", "make_symbol_origin_ref",
         "SymbolOriginValue(value)",
         "SymbolOriginValue(make_symbol_ref(\"x\", namespace_value(), \"x\", \"x\"))"),
        ("path origin rebuild", "identity", "make_path_origin_ref",
         "PathOriginValue(value)",
         "PathOriginValue(make_path_ref(path_ref_owner(value), [\"x\"], path_role_child()))"),
        ("symbol origin equality", "identity", "origin_ref_same",
         "symbol_ref_same(a, b)", "true"),
        ("path origin equality", "identity", "origin_ref_same",
         "path_ref_same(a, b)", "true"),
        ("body ref uniqueness", "core", "validate_core_body_subsequence",
         "!core_body_refs_are_unique(bodies)", "false"),
        ("body order", "core", "validate_core_body_subsequence",
         "body.reference, executable_entry_reference(entry)",
         "body.reference, body.reference"),
        ("body anchor", "core", "validate_core_body_subsequence",
         "body.body_anchor,\n                    executable_contract_body_path(contract)",
         "body.body_anchor, body.body_anchor"),
        ("body final census", "core", "validate_core_body_subsequence",
         "body_index != bodies.len()", "false"),
        ("inventory close", "core", "make_core_program",
         "close_ir_inventory(inventory, manifests)",
         "close_ir_inventory(make_executable_inventory([]), [])"),
        ("closed inventory", "core", "make_core_program",
         "ir_inventory_closure_inventory(closure)", "inventory"),
        ("body copy", "core", "make_core_program",
         "bodies: copy_core_body_entries(bodies)", "bodies: bodies"),
        ("concrete mode", "core", "validate_core_body_subsequence",
         "mode, executable_contract_mode_concrete_body()",
         "mode, executable_contract_mode_contract_only()"),
        ("contract-only mode", "core", "validate_core_body_subsequence",
         "mode, executable_contract_mode_contract_only()",
         "mode, executable_contract_mode_concrete_body()"),
    )
    killed = 0
    for label, source_name, function_name, anchor, replacement in mutations:
        source = identity_source if source_name == "identity" else core_source
        mutated, mutation_error = _f0_mutate_function_once(
            source, function_name, anchor, replacement)
        if mutation_error:
            errors.append(f"C0 mutation {label}: {mutation_error}")
            continue
        assert mutated is not None
        findings = core_hir_c0_contract_errors(
            mutated if source_name == "core" else core_source,
            mutated if source_name == "identity" else identity_source,
            inventory_source)
        if not findings:
            errors.append(f"C0 mutation escaped: {label}")
        else:
            killed += 1

    manual_mutations = (
        ("origin public field", "identity", "pub struct OriginRef {\n    value:",
         "pub struct OriginRef {\n    pub value:"),
        ("origin raw name", "identity", "pub struct OriginRef {\n    value: OriginRefValue",
         "pub struct OriginRef {\n    name: Str,\n    value: OriginRefValue"),
        ("origin raw span", "identity", "pub struct OriginRef {\n    value: OriginRefValue",
         "pub struct OriginRef {\n    span: Span,\n    value: OriginRefValue"),
        ("body public field", "core", "pub struct CoreBodyEntry {\n    reference:",
         "pub struct CoreBodyEntry {\n    pub reference:"),
        ("body anchor type", "core",
         "pub struct CoreBodyEntry {\n    reference: ExecutableRef,\n"
         "    origin: OriginRef,\n    body_anchor: PathRef",
         "pub struct CoreBodyEntry {\n    reference: ExecutableRef,\n"
         "    origin: OriginRef,\n    body_anchor: Str"),
        ("material body", "core",
         "pub struct CoreBodyEntry {\n    reference: ExecutableRef,\n"
         "    origin: OriginRef,\n    body_anchor: PathRef",
         "pub struct CoreBodyEntry {\n    reference: ExecutableRef,\n"
         "    origin: OriginRef,\n    body_anchor: PathRef,\n    body: HExpr"),
        ("program public field", "core", "pub struct CoreProgram {\n    closure:",
         "pub struct CoreProgram {\n    pub closure:"),
        ("duplicate inventory", "core", "closure: IrInventoryClosure,\n    bodies:",
         "closure: IrInventoryClosure,\n    inventory: ExecutableInventory,\n    bodies:"),
        ("duplicate manifests", "core", "closure: IrInventoryClosure,\n    bodies:",
         "closure: IrInventoryClosure,\n    manifests: List<BinderManifest>,\n    bodies:"),
        ("HProgram escape", "core", "pub struct CoreProgram {\n    closure:",
         "pub struct CoreProgram {\n    legacy: HProgram,\n    closure:"),
        ("resource import", "core", "use ir_identity::{",
         "use resource_model::{ParamMode}\nuse ir_identity::{"),
        ("ownership mode", "core", "pub struct CoreProgram {",
         "struct OwnershipMode { take_mode: Bool }\n\npub struct CoreProgram {"),
        ("legacy dict field", "core", "pub struct CoreBodyEntry {",
         "struct LegacyDispatch { value: DictDispatchInfo }\n\npub struct CoreBodyEntry {"),
        ("pipeline conversion", "core", "pub struct CoreProgram {",
         "fn lower_hprogram(program: HProgram) -> CoreProgram { fail.raise() }\n\npub struct CoreProgram {"),
        ("body sorting", "core", "let entries = executable_inventory_entries(inventory)",
         "let entries = executable_inventory_entries(inventory)\n    entries.sort()"),
        ("body accessor", "core", "pub struct CoreProgram {",
         "pub fn core_body(value: CoreBodyEntry) -> HExpr { value.body }\n\npub struct CoreProgram {"),
    )
    for label, source_name, anchor, replacement in manual_mutations:
        source = identity_source if source_name == "identity" else core_source
        if source.count(anchor) != 1:
            errors.append(
                f"C0 mutation {label}: anchor count was {source.count(anchor)}")
            continue
        mutated = source.replace(anchor, replacement, 1)
        findings = core_hir_c0_contract_errors(
            mutated if source_name == "core" else core_source,
            mutated if source_name == "identity" else identity_source,
            inventory_source)
        if not findings:
            errors.append(f"C0 mutation escaped: {label}")
        else:
            killed += 1
    if killed != CORE_HIR_C0_MUTATION_COUNT:
        errors.append(
            f"C0 killed {killed} mutations, expected "
            f"{CORE_HIR_C0_MUTATION_COUNT}")
    return errors


def core_hir_c0_scope_guard_errors(
    core_source: str, identity_source: str, inventory_source: str,
    compiler_sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    mutations = (
        ("main import", "main.ring", "\nuse core_hir::{CoreProgram}\n"),
        ("checker consumer", "checker.ring",
         "\nfn consume_core(value: CoreProgram) {}\n"),
        ("codegen consumer", "codegen_c.ring",
         "\nuse core_hir::{CoreProgram}\n"),
    )
    killed = 0
    for label, file_name, suffix in mutations:
        mutated_sources = dict(compiler_sources)
        mutated_sources[file_name] = compiler_sources[file_name] + suffix
        if not core_hir_c0_live_consumer_errors(mutated_sources):
            errors.append(f"C0 scope guard escaped: {label}")
        else:
            killed += 1
    if killed != CORE_HIR_C0_SCOPE_GUARD_COUNT:
        errors.append(
            f"C0 scope guards killed {killed}, expected "
            f"{CORE_HIR_C0_SCOPE_GUARD_COUNT}")
    return errors


def core_hir_c0_source_errors() -> List[str]:
    try:
        core_source = CORE_HIR_C0_PATH.read_text(encoding="utf-8")
        identity_source = IR_IDENTITY_F0_PATH.read_text(encoding="utf-8")
        inventory_source = IR_INVENTORY_F1_PATH.read_text(encoding="utf-8")
        compiler_sources = {
            path.name: path.read_text(encoding="utf-8")
            for path in (REPO / "compiler").glob("*.ring")
        }
    except (OSError, UnicodeError) as exc:
        return [f"cannot read C0 compiler sources: {exc}"]
    errors = core_hir_c0_contract_errors(
        core_source, identity_source, inventory_source)
    errors.extend(core_hir_c0_live_consumer_errors(compiler_sources))
    if errors:
        return errors
    errors.extend(core_hir_c0_mutation_errors(
        core_source, identity_source, inventory_source))
    errors.extend(core_hir_c0_scope_guard_errors(
        core_source, identity_source, inventory_source, compiler_sources))
    return errors


def core_hir_c0_compile_errors(ring_exe: str) -> List[str]:
    errors: List[str] = []
    compiler = Path(ring_exe).resolve(strict=True)
    before = _sha256_file(compiler)
    environment = dict(_controlled_environment(str(compiler)))
    for source_path in (IR_IDENTITY_F0_PATH, CORE_HIR_C0_PATH):
        error = _f1_run_ring_check(
            str(compiler), source_path, environment)
        if error:
            errors.append(error)
    if _sha256_file(compiler) != before:
        errors.append("pinned Ring compiler changed across C0 checks")
    return errors


B201_BUILTIN_METHODS = (
    ("BUILTIN_METHOD_STR_LEN", "Str", "len", "ring_str_len", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_CONTAINS", "Str", "contains", "ring_str_contains", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_STARTS_WITH", "Str", "starts_with", "ring_str_starts_with", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_ENDS_WITH", "Str", "ends_with", "ring_str_ends_with", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_SLICE", "Str", "slice", "ring_str_slice", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_TRIM", "Str", "trim", "ring_str_trim", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_TO_UPPER", "Str", "to_upper", "ring_str_to_upper", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_TO_LOWER", "Str", "to_lower", "ring_str_to_lower", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_REPLACE", "Str", "replace", "ring_str_replace", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_SPLIT", "Str", "split", "ring_str_split", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_CHAR_AT", "Str", "char_at", "ring_str_char_at", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_INDEX_OF", "Str", "index_of", "ring_str_index_of", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_PAD_START", "Str", "pad_start", "ring_str_pad_start", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_PAD_END", "Str", "pad_end", "ring_str_pad_end", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_REPEAT", "Str", "repeat", "ring_str_repeat", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_CHAR_CODE_AT", "Str", "char_code_at", "ring_str_char_code_at", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_TRIM_START", "Str", "trim_start", "ring_str_trim_start", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_TRIM_END", "Str", "trim_end", "ring_str_trim_end", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_IS_EMPTY", "Str", "is_empty", "ring_str_is_empty", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_STR_LAST_INDEX_OF", "Str", "last_index_of", "ring_str_last_index_of", "register_scalar_method_intrinsics", "str_intrinsics"),
    ("BUILTIN_METHOD_INT_TO_STR", "Int", "to_str", "ring_int_to_str", "register_scalar_method_intrinsics", "int_intrinsics"),
    ("BUILTIN_METHOD_FLOAT_TO_STR", "Float", "to_str", "ring_float_to_str", "register_scalar_method_intrinsics", "float_intrinsics"),
    ("BUILTIN_METHOD_OPTION_UNWRAP_OR", "Option", "unwrap_or", "ring_Option_unwrap_or", "register_option", "intrinsics"),
    ("BUILTIN_METHOD_OPTION_UNWRAP", "Option", "unwrap", "ring_Option_unwrap", "register_option", "intrinsics"),
    ("BUILTIN_METHOD_OPTION_IS_SOME", "Option", "is_some", "ring_Option_is_some", "register_option", "intrinsics"),
    ("BUILTIN_METHOD_OPTION_IS_NONE", "Option", "is_none", "ring_Option_is_none", "register_option", "intrinsics"),
    ("BUILTIN_METHOD_OPTION_MAP", "Option", "map", "ring_Option_map", "register_option_hof", "intrinsics"),
    ("BUILTIN_METHOD_OPTION_AND_THEN", "Option", "and_then", "ring_Option_and_then", "register_option_hof", "intrinsics"),
    ("BUILTIN_METHOD_OPTION_UNWRAP_OR_ELSE", "Option", "unwrap_or_else", "ring_Option_unwrap_or_else", "register_option_hof", "intrinsics"),
    ("BUILTIN_METHOD_OPTION_TO_FAIL", "Option", "to_fail", "ring_Option_to_fail", "register_option", "intrinsics"),
    ("BUILTIN_METHOD_CELL_GET", "Cell", "get", "ring_Cell_get", "register_cell", "intrinsics"),
    ("BUILTIN_METHOD_CELL_SET", "Cell", "set", "ring_Cell_set", "register_cell", "intrinsics"),
    ("BUILTIN_METHOD_CELL_UPDATE", "Cell", "update", "ring_Cell_update", "register_cell", "intrinsics"),
    ("BUILTIN_METHOD_INT_EQ", "Int", "eq", "ring_cl_eq_int", "register_eq_trait", ""),
    ("BUILTIN_METHOD_INT_NE", "Int", "ne", "ring_cl_ne_int", "register_eq_trait", ""),
    ("BUILTIN_METHOD_FLOAT_EQ", "Float", "eq", "ring_cl_eq_float", "register_eq_trait", ""),
    ("BUILTIN_METHOD_FLOAT_NE", "Float", "ne", "ring_cl_ne_float", "register_eq_trait", ""),
    ("BUILTIN_METHOD_STR_EQ", "Str", "eq", "ring_cl_eq_str", "register_eq_trait", ""),
    ("BUILTIN_METHOD_STR_NE", "Str", "ne", "ring_cl_ne_str", "register_eq_trait", ""),
    ("BUILTIN_METHOD_BOOL_EQ", "Bool", "eq", "ring_cl_eq_bool", "register_eq_trait", ""),
    ("BUILTIN_METHOD_BOOL_NE", "Bool", "ne", "ring_cl_ne_bool", "register_eq_trait", ""),
    ("BUILTIN_METHOD_INT_CLONE", "Int", "clone", "ring_dup", "register_clone_trait", ""),
    ("BUILTIN_METHOD_FLOAT_CLONE", "Float", "clone", "ring_dup", "register_clone_trait", ""),
    ("BUILTIN_METHOD_STR_CLONE", "Str", "clone", "ring_dup", "register_clone_trait", ""),
    ("BUILTIN_METHOD_BOOL_CLONE", "Bool", "clone", "ring_dup", "register_clone_trait", ""),
    ("BUILTIN_METHOD_INT_CMP", "Int", "cmp", "ring_cl_cmp_int", "register_ord_trait", ""),
    ("BUILTIN_METHOD_FLOAT_CMP", "Float", "cmp", "ring_cl_cmp_float", "register_ord_trait", ""),
    ("BUILTIN_METHOD_STR_CMP", "Str", "cmp", "ring_cl_cmp_str", "register_ord_trait", ""),
    ("BUILTIN_METHOD_BOOL_CMP", "Bool", "cmp", "ring_cl_cmp_bool", "register_ord_trait", ""),
    ("BUILTIN_METHOD_INT_DEBUG", "Int", "debug", "ring_cl_debug_int", "register_debug_trait", ""),
    ("BUILTIN_METHOD_FLOAT_DEBUG", "Float", "debug", "ring_cl_debug_float", "register_debug_trait", ""),
    ("BUILTIN_METHOD_STR_DEBUG", "Str", "debug", "ring_cl_debug_str", "register_debug_trait", ""),
    ("BUILTIN_METHOD_BOOL_DEBUG", "Bool", "debug", "ring_cl_debug_bool", "register_debug_trait", ""),
    ("BUILTIN_METHOD_INT_HASH", "Int", "hash", "ring_cl_hash_int_export", "register_hash_trait", ""),
    ("BUILTIN_METHOD_STR_HASH", "Str", "hash", "ring_cl_hash_str_export", "register_hash_trait", ""),
    ("BUILTIN_METHOD_BOOL_HASH", "Bool", "hash", "ring_cl_hash_bool_export", "register_hash_trait", ""),
    ("BUILTIN_METHOD_PTR_ADDR", "Ptr", "addr", "", "register_ptr_builtins", "intrinsics"),
    ("BUILTIN_METHOD_PTR_CAST", "Ptr", "cast", "", "register_ptr_builtins", "intrinsics"),
    ("BUILTIN_METHOD_PTR_OFFSET", "Ptr", "offset", "", "register_ptr_builtins", "intrinsics"),
    ("BUILTIN_METHOD_PTR_READ", "Ptr", "read", "", "register_ptr_builtins", "intrinsics"),
    ("BUILTIN_METHOD_PTR_TAKE", "Ptr", "take", "", "register_ptr_builtins", "intrinsics"),
    ("BUILTIN_METHOD_PTR_WRITE", "Ptr", "write", "", "register_ptr_builtins", "intrinsics"),
)
B201_BUILTIN_METHOD_MUTATION_COUNT = 23


def _b201_function_body(
    source: str, function_name: str, errors: List[str],
) -> str:
    body, body_error = _f0_function_body(source, function_name)
    if body_error:
        errors.append(body_error.replace("F0 function", "B-201 function"))
        return ""
    assert body is not None
    return body


def _b201_runtime_names(
    source: str,
) -> Tuple[Optional[List[str]], Optional[str]]:
    masked = mask_ring_strings_and_comments(source)
    pattern = re.compile(
        r"\bconst\s+INTRINSIC_RUNTIME_NAMES\s*:\s*List<Str>\s*=\s*\[")
    matches = list(pattern.finditer(masked))
    if len(matches) != 1:
        return None, (
            f"B-201 runtime name table found {len(matches)} times")
    open_index = masked.rfind("[", matches[0].start(), matches[0].end())
    try:
        close_index = matching_delimiter(masked, open_index, "[", "]")
    except ValueError as exc:
        return None, f"B-201 runtime name table: {exc}"
    body = source[open_index + 1:close_index]
    residue = re.sub(r'"(?:[^"\\]|\\.)*"|[\s,]', "", body)
    if residue:
        return None, f"B-201 runtime table has non-string token {residue!r}"
    return re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', body), None


def builtin_method_intrinsic_contract_errors(
    compiler_sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    identity = compiler_sources["ir_identity.ring"]
    builtins = compiler_sources["builtins.ring"]
    env = compiler_sources["env.ring"]
    hir = compiler_sources["hir.ring"]
    hir_exact = compiler_sources["hir_exact.ring"]
    infer = compiler_sources["infer.ring"]
    infer_helpers = compiler_sources["infer_helpers.ring"]
    zonk = compiler_sources["zonk.ring"]
    core = compiler_sources["core_from_hir.ring"]
    core_expr = compiler_sources["core_expr.ring"]
    flow_lower = compiler_sources["flow_lower.ring"]
    codegen = compiler_sources["codegen_c_expr.ring"]
    runtime = compiler_sources["ring_runtime.cpp"]

    if len(B201_BUILTIN_METHODS) != 62:
        errors.append("B-201 test census is not exact62")
    for tag, method in enumerate(B201_BUILTIN_METHODS):
        constant_name, _, method_name, _, producer, map_name = method
        declaration = f"pub const {constant_name}: Int = {tag}"
        if declaration not in identity:
            errors.append(f"B-201 identity misses {declaration!r}")
        producer_body = _b201_function_body(builtins, producer, errors)
        normalized = re.sub(r"\s+", "", producer_body)
        resource_map = (
            map_name[:-len("_intrinsics")] + "_resources"
            if map_name.endswith("_intrinsics") else "resources"
        )
        relation = re.sub(r"\s+", "", (
            f'install_intrinsic_contract({map_name}, {resource_map}, '
            f'"{method_name}", {constant_name},'
            if map_name else
            f'builtin_intrinsic_method("{method_name}", {constant_name},'
        ))
        if relation not in normalized:
            errors.append(
                f"B-201 producer {producer} misses {constant_name}/{method_name}")
    if "pub const BUILTIN_METHOD_SITE_COUNT: Int = 62" not in identity:
        errors.append("B-201 identity site census drifted")
    ptr_producer = re.sub(r"\s+", "", _b201_function_body(
        builtins, "register_ptr_builtins", errors))
    ptr_resource_relations = (
        'install_intrinsic_contract(intrinsics,resources,"addr",'
        'BUILTIN_METHOD_PTR_ADDR,builtin_resource_contract('
        '[callable_resource_role_read()],callable_resource_role_read(),[]))',
        'install_intrinsic_contract(intrinsics,resources,"cast",'
        'BUILTIN_METHOD_PTR_CAST,builtin_resource_contract('
        '[callable_resource_role_read()],callable_resource_role_read(),[0]))',
        'install_intrinsic_contract(intrinsics,resources,"offset",'
        'BUILTIN_METHOD_PTR_OFFSET,builtin_resource_contract('
        '[callable_resource_role_read(),callable_resource_role_read()],'
        'callable_resource_role_read(),[0]))',
        'install_intrinsic_contract(intrinsics,resources,"read",'
        'BUILTIN_METHOD_PTR_READ,builtin_resource_contract('
        '[callable_resource_role_read()],callable_resource_role_consume(),[]))',
        'install_intrinsic_contract(intrinsics,resources,"take",'
        'BUILTIN_METHOD_PTR_TAKE,builtin_resource_contract('
        '[callable_resource_role_read()],callable_resource_role_consume(),[]))',
        'install_intrinsic_contract(intrinsics,resources,"write",'
        'BUILTIN_METHOD_PTR_WRITE,builtin_resource_contract('
        '[callable_resource_role_read(),callable_resource_role_consume()],'
        'callable_resource_role_read(),[]))',
    )
    for relation in ptr_resource_relations:
        if relation not in ptr_producer:
            errors.append(
                f"B-201 Ptr resource relation misses {relation!r}")
    if "scalar_trait_intrinsic_tag" in mask_ring_strings_and_comments(builtins):
        errors.append("B-201 scalar intrinsic identity is reconstructed by names")
    if "struct BuiltinImplMethodSpec" not in builtins or not all(
            token in builtins for token in (
                "intrinsic_tag: Int?",
                "resource_contract: CallableResourceContractFact?")):
        errors.append(
            "B-201 builtin declaration lacks exact intrinsic/resource facts")

    for struct_name, expected_fields in (
        ("BuiltinMethodSite", ["tag"]),
        ("IntrinsicRef", ["site", "symbol"]),
        ("MethodCallRef", ["value", "signature", "receiver_mutable"]),
        ("BuiltinMethodContractFact", [
            "intrinsic", "target_owner", "target_owner_type_vars",
            "method_type_vars", "scheme", "resource",
        ]),
    ):
        source = (
            hir_exact if struct_name == "MethodCallRef"
            else builtins if struct_name == "BuiltinMethodContractFact"
            else identity
        )
        fields, field_error = _f0_struct_fields(source, struct_name)
        if field_error:
            errors.append(field_error.replace("F0 struct", "B-201 struct"))
            continue
        assert fields is not None
        if [name for _, name in fields] != expected_fields:
            errors.append(f"B-201 {struct_name} field inventory drifted")
        if any(is_public for is_public, _ in fields):
            errors.append(f"B-201 {struct_name} exposes forgeable fields")

    identity_ctor = _b201_function_body(
        identity, "make_builtin_method_intrinsic_ref", errors)
    for token in (
        "builtin_method_site_tag(site)",
        'symbol_ref_origin_module_key(symbol) != "$builtin"',
        "namespace_value()", '"builtin-method:${tag.to_str()}"',
        '"builtin:method-site:${tag.to_str()}"',
    ):
        if token not in identity_ctor:
            errors.append(f"B-201 IntrinsicRef constructor misses {token!r}")

    impl_fields, impl_error = _f0_struct_fields(env, "ImplEntry")
    if impl_error:
        errors.append(impl_error.replace("F0 struct", "B-201 ImplEntry"))
    elif impl_fields is not None and any(
            [name for _, name in impl_fields].count(field) != 1
            for field in ("method_intrinsics", "method_resource_contracts")):
        errors.append(
            "B-201 ImplEntry lacks one intrinsic/resource relation payload")
    impl_validator = _b201_function_body(env, "validate_impl_entry", errors)
    for token in (
        "entry.method_intrinsics.entries()",
        "entry.method_schemes.contains_key(method_name)",
        "entry.method_resource_contracts.contains_key(method_name)",
        "entry.method_resource_contracts.entries()",
        "callable_resource_contract_parameter_roles(contract).len() != arity",
    ):
        if token not in impl_validator:
            errors.append(f"B-201 ImplEntry validator misses {token!r}")
    impl_same = _b201_function_body(env, "impl_entry_final_same", errors)
    for token in (
            "method_intrinsic_map_same(",
            "method_resource_contract_map_same("):
        if token not in impl_same:
            errors.append(f"B-201 full owner equality drops {token!r}")

    intrinsic_source = _b201_function_body(
        builtins, "registered_intrinsic_source", errors)
    for token in (
            "intrinsic_ref_same(candidate, intrinsic)",
            "owner.method_schemes.get(method_name)"):
        if token not in intrinsic_source:
            errors.append(f"B-201 exact registry source misses {token!r}")
    resource_source = _b201_function_body(
        builtins, "registered_intrinsic_resource_contract", errors)
    for token in (
            "intrinsic_ref_same(candidate, intrinsic)",
            "owner.method_resource_contracts.get(method_name)"):
        if token not in resource_source:
            errors.append(f"B-201 exact resource registry misses {token!r}")

    facts_body = _b201_function_body(
        builtins, "builtin_method_contract_facts", errors)
    for token in (
        "for tag in 0..BUILTIN_METHOD_SITE_COUNT",
        "registered_intrinsic_source(env, intrinsic)",
        "make_builtin_method_contract_fact(",
        "registered_intrinsic_resource_contract(env, intrinsic)",
        "result.len() != BUILTIN_METHOD_SITE_COUNT",
    ):
        if token not in facts_body:
            errors.append(f"B-201 typed contract producer misses {token!r}")

    core_contracts = _b201_function_body(
        core, "add_builtin_method_contracts", errors)
    for token in (
        "facts.builtin_methods.len() != BUILTIN_METHOD_SITE_COUNT",
        "builtin_method_contract_intrinsic(fact)",
        "intrinsic_ref_same(",
        "make_named_executable_ref(",
        "intrinsic_ref_symbol(intrinsic)",
        "executable_kind_builtin_intrinsic()",
        "make_contract_only()",
        "builtin_method_contract_resource(fact)",
    ):
        if token not in core_contracts:
            errors.append(f"B-201 real Core consumer misses {token!r}")

    method_ctor = _b201_function_body(
        hir_exact, "make_intrinsic_method_call_ref", errors)
    if "Type::FnType { .. }" not in method_ctor:
        errors.append("B-201 MethodCallRef accepts a non-callable signature")
    method_same = _b201_function_body(
        hir_exact, "method_call_ref_same", errors)
    for token in (
            "intrinsic_ref_same(", "trait_method_ref_same(",
            "dict_ref_same(", "types_equal("):
        if token not in method_same:
            errors.append(f"B-201 MethodCallRef equality misses {token!r}")
    if re.search(
            r"Call\s*\{[^{}]*\bmethod_ref\s*:\s*MethodCallRef\?",
            mask_ring_strings_and_comments(hir)) is None:
        errors.append("B-201 HExpr::Call lacks exact MethodCallRef carrier")
    hir_validator = _b201_function_body(hir, "validate_hir_expr", errors)
    for token in (
        "some(exact_method)", "HFieldAccessKind::Method",
        "method_call_ref_signature(exact_method)", "types_equal(",
    ):
        if token not in hir_validator:
            errors.append(f"B-201 HIR validator misses {token!r}")

    lookup_impl = _b201_function_body(
        infer_helpers, "lookup_impl_method", errors)
    lookup_trait = _b201_function_body(
        infer_helpers, "lookup_trait_method", errors)
    for label, body in (("impl", lookup_impl), ("trait", lookup_trait)):
        if ".method_intrinsics.get(method)" not in body:
            errors.append(f"B-201 {label} lookup drops exact intrinsic")
    infer_method = _b201_function_body(
        infer, "infer_method_call_from_receiver", errors)
    for token in (
        "intrinsic_ref = r.intrinsic_ref",
        "make_intrinsic_method_call_ref(",
        "method_ref: exact_method_ref",
    ):
        if token not in infer_method:
            errors.append(f"B-201 infer consumer misses {token!r}")
    zonk_helper = _b201_function_body(zonk, "zonk_method_call_ref", errors)
    for token in (
        "method_call_ref_intrinsic(exact)",
        "zonk_type(ctx, method_call_ref_signature(exact))",
    ):
        if token not in zonk_helper:
            errors.append(f"B-201 zonk relation misses {token!r}")

    for file_name, function_name, transport in (
        ("andor_lower.ring", "al_expr", "method_ref: method_ref"),
        ("dict_lower.ring", "dl_expr",
         "method_ref: dl_method_call_ref(method_ref, defs, seen)"),
        ("zonk.ring", "zonk_expr", "method_ref: zonk_method_call_ref(ctx, method_ref)"),
    ):
        body = _b201_function_body(
            compiler_sources[file_name], function_name, errors)
        if transport not in body:
            errors.append(
                f"B-201 {file_name}:{function_name} drops MethodCallRef")

    exact_core = _b201_function_body(core, "exact_method_ref", errors)
    for token in (
            "method_call_ref_is_intrinsic(value)",
            "make_exact_intrinsic_method_ref(method_call_ref_intrinsic(value))",
            'panic("Core assembly: method selection is not exact")'):
        if token not in exact_core:
            errors.append(f"B-201 TypedHIR/Core exact method bridge misses {token!r}")
    core_validation = _b201_function_body(
        core_expr, "validate_method_call_identity", errors)
    for token in (
            "exact_method_ref_is_intrinsic(method)",
            "intrinsic_ref_symbol(",
            "exact_method_ref_intrinsic(method)",
            'panic("CoreHIR: intrinsic method/callee differs")'):
        if token not in core_validation:
            errors.append(f"B-201 Core exact method validation misses {token!r}")
    flow_target = _b201_function_body(flow_lower, "flow_call_target", errors)
    for token in (
            "core_callee_kind_tag(value)",
            "make_direct_flow_call_target(",
            "core_callee_direct(value)",
            'panic("Flow lowering: unknown Core callee form")'):
        if token not in flow_target:
            errors.append(f"B-201 Core/Flow exact callee bridge misses {token!r}")

    runtime_names, runtime_error = _b201_runtime_names(codegen)
    if runtime_error:
        errors.append(runtime_error)
    elif runtime_names != [entry[3] for entry in B201_BUILTIN_METHODS]:
        errors.append("B-201 exact tag-to-ABI projection drifted")
    if "fn method_to_runtime_c(" in mask_ring_strings_and_comments(codegen):
        errors.append("B-201 retained the type/name runtime method table")
    intrinsic_codegen = _b201_function_body(
        codegen, "gen_c_intrinsic_method_call", errors)
    for token in (
        "method_call_ref_signature(method_ref)",
        "method_call_ref_intrinsic(method_ref)",
        "builtin_method_site_tag(", "intrinsic_runtime_name(tag)",
        "rt_use(ctx, runtime_name, call_args.len())",
    ):
        if token not in intrinsic_codegen:
            errors.append(f"B-201 C intrinsic projection misses {token!r}")
    for forbidden in ("type_to_builtin_name", "method_to_runtime_c"):
        if forbidden in intrinsic_codegen:
            errors.append(
                f"B-201 exact C projection reinterprets {forbidden}")
    if "gen_c_ptr_intrinsic(" not in intrinsic_codegen:
        errors.append("B-201 exact C projection drops Ptr inline sites")
    ptr_codegen = _b201_function_body(
        codegen, "gen_c_ptr_intrinsic", errors)
    for constant_name in (
        "BUILTIN_METHOD_PTR_ADDR", "BUILTIN_METHOD_PTR_CAST",
        "BUILTIN_METHOD_PTR_OFFSET", "BUILTIN_METHOD_PTR_READ",
        "BUILTIN_METHOD_PTR_TAKE", "BUILTIN_METHOD_PTR_WRITE",
    ):
        if f"tag == {constant_name}" not in ptr_codegen:
            errors.append(
                f"B-201 Ptr inline projection misses {constant_name}")
    masked_codegen = mask_ring_strings_and_comments(codegen)
    for forbidden in ('type_name == "Ptr"', "gen_c_ptr_method"):
        if forbidden in masked_codegen:
            errors.append(
                f"B-201 Ptr inline projection retains {forbidden}")
    gen_call = _b201_function_body(codegen, "gen_c_call", errors)
    exact_pos = gen_call.find("match method_ref")
    fallback_pos = gen_call.find("let raw = match callee")
    if exact_pos < 0 or fallback_pos < 0 or exact_pos >= fallback_pos:
        errors.append("B-201 exact method consumer does not precede fallback")

    cell_update, cell_update_error = extract_c_function_body(
        runtime, "ring_Cell_update")
    if cell_update_error:
        errors.append(cell_update_error)
    elif cell_update is not None:
        cell_tokens = (
            "*(void**)cell = nullptr", "ring_dup(old_val)",
            "cl->env_ptr, old_val, ring_effect_ctx_empty())",
            "void* interim = *(void**)cell", "*(void**)cell = new_val",
            "if (interim) ring_drop(interim)", "ring_drop(old_val)",
        )
        positions = [cell_update.find(token) for token in cell_tokens]
        if (
            any(position < 0 for position in positions)
            or positions != sorted(positions)
            or cell_update.count("ring_effect_ctx_empty()") != 1
        ):
            errors.append("Cell.update reentrant/immortal-empty context path drifted")

    return errors


def builtin_method_intrinsic_mutation_errors(
    compiler_sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    mutations = (
        ("site count", "ir_identity.ring", None,
         "pub const BUILTIN_METHOD_SITE_COUNT: Int = 62",
         "pub const BUILTIN_METHOD_SITE_COUNT: Int = 61"),
        ("tag duplicate", "ir_identity.ring", None,
         "pub const BUILTIN_METHOD_STR_CONTAINS: Int = 1",
         "pub const BUILTIN_METHOD_STR_CONTAINS: Int = 0"),
        ("symbol payload", "ir_identity.ring", "make_builtin_method_intrinsic_ref",
         '"builtin-method:${tag.to_str()}"', '"builtin-method"'),
        ("producer swap", "builtins.ring", "register_scalar_method_intrinsics",
         "BUILTIN_METHOD_STR_LEN", "BUILTIN_METHOD_STR_CONTAINS"),
        ("scalar producer swap", "builtins.ring", "register_eq_trait",
         "BUILTIN_METHOD_INT_EQ", "BUILTIN_METHOD_INT_NE"),
        ("option producer", "builtins.ring", "register_option",
         "BUILTIN_METHOD_OPTION_UNWRAP, builtin_resource_contract(",
         "BUILTIN_METHOD_OPTION_UNWRAP_OR, builtin_resource_contract("),
        ("cell producer", "builtins.ring", "register_cell",
         "BUILTIN_METHOD_CELL_SET, builtin_resource_contract(",
         "BUILTIN_METHOD_CELL_GET, builtin_resource_contract("),
        ("Ptr producer", "builtins.ring", "register_ptr_builtins",
         "BUILTIN_METHOD_PTR_ADDR, builtin_resource_contract(",
         "BUILTIN_METHOD_PTR_CAST, builtin_resource_contract("),
        ("Ptr resource", "builtins.ring", "register_ptr_builtins",
         "BUILTIN_METHOD_PTR_WRITE, builtin_resource_contract(\n"
         "            [callable_resource_role_read(), callable_resource_role_consume()],",
         "BUILTIN_METHOD_PTR_WRITE, builtin_resource_contract(\n"
         "            [callable_resource_role_read(), callable_resource_role_read()],"),
        ("owner scheme relation", "env.ring", "validate_impl_entry",
         "for intrinsic_entry in entry.method_intrinsics.entries()",
         "for intrinsic_entry in []"),
        ("owner resource equality", "env.ring", "impl_entry_final_same",
         "method_resource_contract_map_same(", "method_core_map_same("),
        ("registry intrinsic lookup", "builtins.ring",
         "registered_intrinsic_source",
         "intrinsic_ref_same(candidate, intrinsic)", "true"),
        ("registry resource lookup", "builtins.ring",
         "registered_intrinsic_resource_contract",
         "owner.method_resource_contracts.get(method_name)",
         'owner.method_resource_contracts.get("wrong")'),
        ("typed fact census", "builtins.ring", "builtin_method_contract_facts",
         "for tag in 0..BUILTIN_METHOD_SITE_COUNT", "for tag in 0..0"),
        ("Core contract resource", "core_from_hir.ring",
         "add_builtin_method_contracts",
         "builtin_method_contract_resource(fact)",
         "missing_builtin_resource_contract(fact)"),
        ("call signature kind", "hir_exact.ring", "make_intrinsic_method_call_ref",
         "Type::FnType { .. }", "_"),
        ("infer publish", "infer.ring", "infer_method_call_from_receiver",
         "method_ref: exact_method_ref", "method_ref: none"),
        ("TypedHIR/Core bridge", "core_from_hir.ring", "exact_method_ref",
         "make_exact_intrinsic_method_ref(method_call_ref_intrinsic(value))",
         "make_exact_trait_method_ref(method_call_ref_bound(value))"),
        ("Core/Flow direct target", "flow_lower.ring", "flow_call_target",
         "make_direct_flow_call_target(", "make_dynamic_flow_call_target("),
        ("ABI order", "codegen_c_expr.ring", None,
         '"ring_str_len", "ring_str_contains"',
         '"ring_str_contains", "ring_str_len"'),
        ("Ptr inline", "codegen_c_expr.ring", "gen_c_ptr_intrinsic",
         "tag == BUILTIN_METHOD_PTR_ADDR",
         "tag == BUILTIN_METHOD_PTR_CAST"),
        ("name fallback", "codegen_c_expr.ring", None,
         "fn intrinsic_runtime_name(tag: Int) -> Str {",
         "fn method_to_runtime_c(type_name: Str, method: Str) -> Str? { none }\n\nfn intrinsic_runtime_name(tag: Int) -> Str {"),
        ("Cell.update context fallback", "ring_runtime.cpp", None,
         "cl->env_ptr, old_val, ring_effect_ctx_empty());",
         "cl->env_ptr, old_val, effect_ctx);"),
    )
    killed = 0
    for label, file_name, function_name, anchor, replacement in mutations:
        mutated_sources = dict(compiler_sources)
        if function_name is None:
            source = compiler_sources[file_name]
            if source.count(anchor) != 1:
                errors.append(
                    f"B-201 mutation {label}: anchor count was {source.count(anchor)}")
                continue
            mutated_sources[file_name] = source.replace(anchor, replacement, 1)
        else:
            mutated, mutation_error = _f0_mutate_function_once(
                compiler_sources[file_name], function_name, anchor, replacement)
            if mutation_error:
                errors.append(f"B-201 mutation {label}: {mutation_error}")
                continue
            assert mutated is not None
            mutated_sources[file_name] = mutated
        findings = builtin_method_intrinsic_contract_errors(mutated_sources)
        if not findings:
            errors.append(f"B-201 mutation escaped: {label}")
        else:
            killed += 1
    if killed != B201_BUILTIN_METHOD_MUTATION_COUNT:
        errors.append(
            f"B-201 killed {killed} mutations, expected "
            f"{B201_BUILTIN_METHOD_MUTATION_COUNT}")
    return errors


def builtin_method_intrinsic_source_errors() -> List[str]:
    try:
        compiler_sources = {
            path.name: path.read_text(encoding="utf-8")
            for path in (REPO / "compiler").glob("*.ring")
        }
        compiler_sources[RUNTIME_CPP.name] = RUNTIME_CPP.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read B-201 sources: {exc}"]
    errors = builtin_method_intrinsic_contract_errors(compiler_sources)
    if errors:
        return errors
    errors.extend(builtin_method_intrinsic_mutation_errors(compiler_sources))
    return errors


B201_IMPL_EXTERN_RECOVERY_CASES = (
    REPO / "tests" / "cases" / "error_impl_block_duplicate_fn_extern.ring",
    REPO / "tests" / "cases" / "error_trait_impl_pub_extern_recovery.ring",
)


def builtin_impl_extern_recovery_errors(ring_exe: str) -> List[str]:
    errors: List[str] = []
    expected_message = "impl-member extern fn is not part of Ring 0.1"
    for source_path in B201_IMPL_EXTERN_RECOVERY_CASES:
        contract = source_path.with_suffix(".error").read_text(encoding="utf-8")
        for mode, extra_args in (
                ("human", None), ("llm", ["--error-format=llm"])):
            label = f"{source_path.name}:{mode}"
            try:
                result = ring_check(
                    ring_exe, str(source_path), extra_args=extra_args,
                    phase_suite="structural",
                    phase_case=f"b201-impl-extern:{label}")
            except subprocess.TimeoutExpired:
                errors.append(f"B-201 {label} timed out")
                continue
            combined = (result.stdout or "") + (result.stderr or "")
            if result.returncode == 0:
                errors.append(f"B-201 {label} unexpectedly succeeded")
                continue
            contract_error = error_contract_failure(contract, combined)
            if contract_error is not None:
                errors.append(f"B-201 {label}: {contract_error}")
                continue
            codes = set(re.findall(r"\bE[0-9]{4}\b", combined))
            if codes != {"E0103"}:
                errors.append(
                    f"B-201 {label} diagnostic set drifted: {sorted(codes)!r}")
            if combined.count(expected_message) != 1:
                errors.append(
                    f"B-201 {label} emitted the rejection message "
                    f"{combined.count(expected_message)} times")
    return errors


F2_U1A_SOURCE_CONTRACT_MUTATIONS = (
    # Resolver source-site and exact namespace construction.
    ("resolver", "source_declaration_site_path", "site.use_index != -1",
     "false"),
    ("resolver", "source_declaration_site_path",
     '"frame:${site.frame_index}|item:${site.item_index}"',
     '"frame:${site.frame_index}|use:${site.use_index}|item:${site.item_index}"'),
    ("resolver", "source_declaration_site_path",
     '"frame:${site.frame_index}|item:${site.item_index}"',
     '"frame:${site.frame_index}|item:${site.item_index}|owner:forged"'),
    ("resolver", "source_declaration_site_path",
     '"frame:${site.frame_index}|item:${site.item_index}"',
     '"frame:${site.frame_index}|item:${site.item_index}|name:forged"'),
    ("resolver", "source_declaration_site_path",
     '"frame:${site.frame_index}|item:${site.item_index}"',
     '"frame:${site.frame_index}|item:${site.item_index}|payload:forged"'),
    ("resolver", "source_declaration_site_path",
     '"frame:${site.frame_index}|item:${site.item_index}"',
     '"frame:${site.frame_index}|item:${site.item_index}|ordinal:${site.item_index}"'),
    ("resolver", "source_seed_symbol",
     "file_key != origin_site.file_key", "false"),
    ("resolver", "source_seed_symbol",
     "frame_index != origin_site.frame_index", "false"),
    ("resolver", "source_seed_symbol",
     "decl_index != origin_site.item_index", "false"),
    ("resolver", "source_seed_symbol",
     "NamespaceKind::Value => namespace_value()",
     "NamespaceKind::Value => namespace_nominal()"),
    ("resolver", "source_seed_symbol",
     "NamespaceKind::Struct => namespace_nominal()",
     "NamespaceKind::Struct => namespace_value()"),
    ("resolver", "source_seed_symbol",
     "NamespaceKind::Enum => namespace_nominal()",
     "NamespaceKind::Enum => namespace_value()"),
    ("resolver", "source_seed_symbol",
     "NamespaceKind::TypeAlias => namespace_nominal()",
     "NamespaceKind::TypeAlias => namespace_value()"),
    ("resolver", "source_seed_symbol",
     "NamespaceKind::Effect => namespace_effect()",
     "NamespaceKind::Effect => namespace_value()"),
    ("resolver", "source_seed_symbol",
     "NamespaceKind::EffectAlias => namespace_effect()",
     "NamespaceKind::EffectAlias => namespace_value()"),
    ("resolver", "source_seed_symbol",
     "NamespaceKind::Trait => namespace_trait()",
     "NamespaceKind::Trait => namespace_value()"),
    ("resolver", "source_seed_symbol",
     "symbol_ref_origin_module_key(symbol) != origin_site.file_key", "false"),
    ("resolver", "source_seed_symbol", "!namespace_kind_same(",
     "false && namespace_kind_same("),
    ("resolver", "append_namespace_seed", "source_seed_symbol(",
     "source_seed_symbol_missing("),
    ("resolver", "append_namespace_seed",
     "namespace: namespace,\n        symbol: symbol,\n        is_public: effective_public",
     "namespace: namespace,\n        symbol: existing_symbol.unwrap(),\n        is_public: effective_public"),
    ("resolver", "append_namespace_seed",
     "namespace: namespace,\n            symbol: symbol,\n            is_public: true",
     "namespace: namespace,\n            symbol: existing_symbol.unwrap(),\n            is_public: true"),
    ("resolver", "append_enum_variant_fact_group",
     "symbol_ref_same(group.enum_symbol, enum_symbol)", "false"),
    ("resolver", "append_enum_variant_fact_group",
     "symbol_ref_same(group.enum_symbol, enum_symbol)",
     "symbol_ref_same(group.enum_symbol, group.enum_symbol)"),
    ("resolver", "enum_variant_constructors",
     "symbol_ref_same(group.enum_symbol, enum_symbol)", "false"),
    ("resolver", "claim_named_enum_relation_expansion",
     "symbol_ref_same(expanded.enum_symbol, enum_symbol)", "false"),
    ("resolver", "collect_decl_seed",
     "symbol: ctor_symbol,\n                    is_public:",
     "symbol: enum_symbol,\n                    is_public:"),
    ("resolver", "collect_decl_seed", "some(ctor_symbol), is_pub",
     "some(enum_symbol), is_pub"),
    ("resolver", "binding_with_public", "symbol: binding.symbol",
     "symbol: candidate.symbol"),
    ("resolver", "add_namespace_fact",
     "symbol_ref_same(existing.symbol, candidate.symbol)",
     "symbol_ref_same(candidate.symbol, candidate.symbol)"),
    ("resolver", "add_namespace_fact",
     "symbol_ref_same(existing.symbol, candidate.symbol)", "false"),
    ("resolver", "reduce_value_lane", "symbol_ref_same(\n"
     "                           existing.binding.symbol,\n"
     "                           candidate.binding.symbol)",
     "symbol_ref_same(candidate.binding.symbol, "
     "candidate.binding.symbol)"),
    ("resolver", "project_public_inline_fact", "symbol: fact.symbol",
     "symbol: candidate.symbol"),
    ("resolver", "deliver_namespace_fact", "symbol: fact.symbol",
     "symbol: ctor.symbol"),
    ("resolver", "materialize_structural_producer",
     "ValueStructuralProducerSource::ImportCopyValue { .. } => match source {",
     "ValueStructuralProducerSource::TerminalValue(_) => match source {"),
    ("resolver", "materialize_structural_producer",
     "ValueStructuralProducerSource::ProjectionCopyValue { .. } => match source {",
     "ValueStructuralProducerSource::TerminalValue(_) => match source {"),
    ("resolver", "append_distinct_symbol_ref",
     "symbol_ref_same(existing, symbol)", "symbol_ref_same(symbol, symbol)"),
    ("resolver", "append_materialized_strong_ambiguity",
     "!symbol_ref_same(\n"
     "                                       left.binding.symbol,\n"
     "                                       right.binding.symbol)",
     "!symbol_ref_same(left.binding.symbol, left.binding.symbol)"),
    ("resolver", "materialize_structural_value_plan",
     "symbol_ref_same(\n"
     "                                                publication.binding.symbol,\n"
     "                                                local.binding.symbol)",
     "symbol_ref_same(publication.binding.symbol, "
     "publication.binding.symbol)"),
    ("resolver", "materialize_cycle_import_producer",
     "materialize_value_binding(producer.target, symbol)",
     "materialize_value_binding(producer.target, forged_symbol)"),
    # InferCtx may only project an already-resolved symbol to legacy lookup.
    ("infer_ctx", "apply_project_value_binding",
     "symbol_ref_canonical_payload(binding.symbol)", "binding.exposed_name"),
    ("infer_ctx", "apply_project_namespace_binding",
     "symbol_ref_canonical_payload(binding.symbol)", "binding.exposed_name"),
    ("infer_ctx", "install_project_namespace_plan",
     "symbol_ref_canonical_payload(group.enum_symbol)", "group.enum_symbol"),
    ("infer_ctx", "install_project_namespace_plan",
     "symbol_ref_canonical_payload(ctor.symbol)", "ctor.exposed_name"),
)


def _f2_u1a_relation_finding(
    source_name: str, function_name: str, token: str,
) -> str:
    return (
        f"F2 U1a {source_name}.{function_name} misses relation {token!r}")


def _f2_u1a_require_function_token(
    source: str, source_name: str, function_name: str, token: str,
    errors: List[str],
) -> None:
    body, body_error = _f0_function_body(source, function_name)
    if body_error:
        errors.append(body_error.replace(
            "F0 function", f"F2 U1a {source_name} function"))
        return
    assert body is not None
    if token not in body:
        errors.append(_f2_u1a_relation_finding(
            source_name, function_name, token))


def _f2_u1a_struct_fields(
    source: str, name: str, expected: List[str], errors: List[str],
) -> None:
    masked = mask_ring_strings_and_comments(source)
    pattern = re.compile(
        rf"\b(?:pub\s+)?struct\s+{re.escape(name)}\s*\{{")
    matches = list(pattern.finditer(masked))
    if len(matches) != 1:
        errors.append(f"F2 U1a struct {name} found {len(matches)} times")
        return
    open_index = masked.rfind("{", matches[0].start(), matches[0].end())
    try:
        close_index = matching_delimiter(masked, open_index, "{", "}")
    except ValueError as exc:
        errors.append(f"F2 U1a struct {name}: {exc}")
        return
    body = masked[open_index + 1:close_index]
    actual = [
        match.group(1)
        for match in re.finditer(
            r"(?m)^\s*(?:pub\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:", body)
    ]
    if actual != expected:
        errors.append(
            f"F2 U1a {name} field inventory drifted: {actual!r}")


def _f2_u1a_call_escaped_function_allowlist(
    source: str, call_token: str, allowed_functions: Tuple[str, ...],
) -> bool:
    allowed_spans: List[Tuple[int, int]] = []
    for function_name in allowed_functions:
        span, span_error = _f0_function_span(source, function_name)
        if span_error is not None or span is None:
            continue
        allowed_spans.append(span)
    # Ring string interpolation contains executable expressions.  Scan raw
    # source so an accessor hidden inside "${...}" cannot evade the allowlist.
    for match in re.finditer(re.escape(call_token), source):
        if not any(start <= match.start() < end for start, end in allowed_spans):
            return True
    return False


def resolver_identity_u1a_contract_errors(
    resolver_source: str, infer_ctx_source: str,
) -> List[str]:
    """Cheap layout-sensitive source guards, not semantic acceptance.

    These checks intentionally do not duplicate the Ring parser and make no
    claim that formatting-equivalent rewrites cannot evade them.  U1a behavior
    is accepted only from a source-built candidate running targeted project
    fixtures in an external Steward evidence packet.
    """
    errors: List[str] = []
    resolver_masked = mask_ring_strings_and_comments(resolver_source)
    infer_masked = mask_ring_strings_and_comments(infer_ctx_source)

    _f2_u1a_struct_fields(resolver_source, "NamespaceSeed", [
        "file_key", "frame_index", "decl_index", "origin_site", "owner",
        "exposed_name", "namespace", "symbol", "is_public", "role",
        "is_projection"], errors)
    _f2_u1a_struct_fields(resolver_source, "ResolvedNamespaceBinding", [
        "file_key", "frame_index", "owner", "exposed_name", "namespace",
        "symbol", "is_public"], errors)
    _f2_u1a_struct_fields(resolver_source, "EnumVariantFactGroup", [
        "enum_symbol", "constructors"], errors)
    _f2_u1a_struct_fields(resolver_source, "ValueBindingTarget", [
        "file_key", "frame_index", "owner", "exposed_name", "is_public"],
        errors)
    _f2_u1a_struct_fields(resolver_source, "ValueStructuralProducer", [
        "producer", "target", "occurrence", "source"], errors)
    _f2_u1a_struct_fields(resolver_source, "ValueStructuralSlot", [
        "target", "producers", "local_announced", "publication_announced",
        "projection_registered", "has_public_seed_terminal",
        "local_winner_index", "publication_winner_index"], errors)

    for token in (
            "TerminalValue(SymbolRef)", "ImportCopyValue {",
            "ProjectionCopyValue {"):
        if token not in resolver_masked:
            errors.append(
                f"F2 U1a payload-free Value source misses {token!r}")
    if ".payload" in resolver_masked or "payload: \"\"" in resolver_source:
        errors.append("F2 U1a resolver retained raw payload authority")

    if resolver_source.count("make_symbol_ref(") != 1:
        errors.append("F2 U1a resolver make_symbol_ref authority drifted")
    source_seed_body, source_seed_error = _f0_function_body(
        resolver_source, "source_seed_symbol")
    if source_seed_error:
        errors.append(source_seed_error.replace(
            "F0 function", "F2 U1a resolver function"))
    elif source_seed_body is not None and "make_symbol_ref(" not in source_seed_body:
        errors.append("F2 U1a source seed helper no longer owns construction")

    required_imports = (
        "SymbolRef", "make_symbol_ref", "namespace_value",
        "namespace_nominal", "namespace_trait", "namespace_effect",
        "namespace_kind_same",
        "symbol_ref_origin_module_key", "symbol_ref_namespace_kind",
        "symbol_ref_canonical_payload", "symbol_ref_declaration_site_path",
        "symbol_ref_same",
    )
    for token in required_imports:
        if token not in resolver_source[:1200]:
            errors.append(f"F2 U1a resolver import misses {token!r}")

    seen_relations: set[Tuple[str, str, str]] = set()
    for source_name, function_name, token, _ in (
            F2_U1A_SOURCE_CONTRACT_MUTATIONS):
        relation = (source_name, function_name, token)
        if relation in seen_relations:
            continue
        seen_relations.add(relation)
        source = resolver_source if source_name == "resolver" else infer_ctx_source
        _f2_u1a_require_function_token(
            source, source_name, function_name, token, errors)

    if _f2_u1a_call_escaped_function_allowlist(
            resolver_source, "symbol_ref_canonical_payload(",
            ("source_seed_symbol", "append_binding_ambiguity")):
        errors.append(
            "F2 U1a resolver canonical payload call escaped function allowlist")
    if re.search(
            r"(?:[A-Za-z_][A-Za-z0-9_.]*\.(?:symbol|enum_symbol)|"
            r"[A-Za-z_][A-Za-z0-9_]*(?:_symbol|symbol))\s*(?:==|!=)|"
            r"(?:==|!=)\s*(?:[A-Za-z_][A-Za-z0-9_.]*\."
            r"(?:symbol|enum_symbol)|[A-Za-z_][A-Za-z0-9_]*"
            r"(?:_symbol|symbol))\b",
            resolver_source):
        errors.append("F2 U1a resolver used raw SymbolRef equality")

    if "make_symbol_ref" in infer_masked:
        errors.append("F2 U1a infer_ctx reconstructs SymbolRef")
    if re.search(r"Map\s*<\s*Str\s*,\s*SymbolRef\s*>", infer_masked):
        errors.append("F2 U1a infer_ctx gained typed origin side map")
    if _f2_u1a_call_escaped_function_allowlist(
            infer_ctx_source, "symbol_ref_canonical_payload(",
            ("apply_project_value_binding",
             "apply_project_namespace_binding",
             "install_project_namespace_plan")):
        errors.append(
            "F2 U1a infer_ctx canonical payload call escaped function allowlist")
    key_body, key_error = _f0_function_body(
        infer_ctx_source, "project_binding_key")
    if key_error:
        errors.append(key_error.replace(
            "F0 function", "F2 U1a infer_ctx function"))
    elif key_body is not None and (
            "binding.symbol" in key_body and
            "symbol_ref_canonical_payload" not in key_body):
        errors.append("F2 U1a project binding key became origin authority")

    for forbidden in (
            "CoreHIR", "FlowIR", "RcIR", "CalleeRef", "SourceBinder",
            "source_binder", "member_identity", "single_namespace_cutover"):
        if forbidden in resolver_masked or forbidden in infer_masked:
            errors.append(f"F2 U1a exceeded resolver-origin scope via {forbidden!r}")
    return errors


def resolver_identity_u1a_source_contract_mutation_errors(
    resolver_source: str, infer_ctx_source: str,
) -> Tuple[List[str], int]:
    """Exercise inexpensive source-contract regressions only."""
    errors: List[str] = []
    count = 0
    for source_name, function_name, anchor, replacement in (
            F2_U1A_SOURCE_CONTRACT_MUTATIONS):
        count += 1
        source = resolver_source if source_name == "resolver" else infer_ctx_source
        mutated, mutation_error = _f0_mutate_function_once(
            source, function_name, anchor, replacement)
        if mutation_error:
            errors.append(
                f"F2 U1a source-contract mutation "
                f"{source_name}.{function_name}: "
                f"{mutation_error}")
            continue
        assert mutated is not None
        findings = resolver_identity_u1a_contract_errors(
            mutated if source_name == "resolver" else resolver_source,
            mutated if source_name == "infer_ctx" else infer_ctx_source)
        expected = _f2_u1a_relation_finding(
            source_name, function_name, anchor)
        if findings != [expected]:
            errors.append(
                f"F2 U1a source-contract mutation "
                f"{source_name}.{function_name} "
                f"findings were {findings!r}, expected only {expected!r}")

    custom_mutations = (
        ("NamespaceSeed parallel payload", "resolver",
         "pub symbol: SymbolRef,\n    pub is_public: Bool,",
         "pub payload: Str,\n    pub is_public: Bool,",
         "F2 U1a NamespaceSeed field inventory drifted"),
        ("Resolved binding parallel payload", "resolver",
         "pub symbol: SymbolRef,\n    pub is_public: Bool\n}",
         "pub payload: Str,\n    pub is_public: Bool\n}",
         "F2 U1a ResolvedNamespaceBinding field inventory drifted"),
        ("Value target forged symbol", "resolver",
         "struct ValueBindingTarget {\n    file_key: Str,",
         "struct ValueBindingTarget {\n    symbol: SymbolRef,\n    file_key: Str,",
         "F2 U1a ValueBindingTarget field inventory drifted"),
        ("optional terminal symbol", "resolver",
         "TerminalValue(SymbolRef)", "TerminalValue(Option<SymbolRef>)",
         "F2 U1a payload-free Value source misses 'TerminalValue(SymbolRef)'"),
        ("second resolver constructor", "resolver", "\nfn declaration_payload(",
         "\nfn forged_symbol() { let _ = make_symbol_ref(\"\", namespace_value(), \"\", \"\") }\n\nfn declaration_payload(",
         "F2 U1a resolver make_symbol_ref authority drifted"),
        ("infer reverse construction", "infer_ctx", "\n// ============================================================\n// Error helper",
         "\nfn infer_forged_symbol() { let _ = make_symbol_ref(\"\", namespace_value(), \"\", \"\") }\n\n"
         "// ============================================================\n// Error helper",
         "F2 U1a infer_ctx reconstructs SymbolRef"),
        ("infer typed side index", "infer_ctx", "\n// ============================================================\n// Error helper",
         "\nstruct InferOriginSideMap { values: Map<Str, SymbolRef> }\n\n"
         "// ============================================================\n// Error helper",
         "F2 U1a infer_ctx gained typed origin side map"),
        ("application key consumes origin", "infer_ctx",
         '"${namespace}|${binding.exposed_name}"',
         '"${namespace}|${binding.exposed_name}|${symbol_ref_canonical_payload(binding.symbol)}"',
         "F2 U1a infer_ctx canonical payload call escaped function allowlist"),
        ("cycle canonical collapse", "resolver",
         "if symbol_ref_same(existing, symbol) { return }",
         "if symbol_ref_same(existing, symbol) || "
         "symbol_ref_canonical_payload(existing) == "
         "symbol_ref_canonical_payload(symbol) { return }",
         "F2 U1a resolver canonical payload call escaped function allowlist"),
    )
    for label, source_name, anchor, replacement, expected_prefix in custom_mutations:
        count += 1
        source = resolver_source if source_name == "resolver" else infer_ctx_source
        if source.count(anchor) != 1:
            errors.append(
                f"F2 U1a source-contract mutation {label} anchor count was "
                f"{source.count(anchor)}")
            continue
        mutated = source.replace(anchor, replacement, 1)
        findings = resolver_identity_u1a_contract_errors(
            mutated if source_name == "resolver" else resolver_source,
            mutated if source_name == "infer_ctx" else infer_ctx_source)
        if len(findings) != 1 or not findings[0].startswith(expected_prefix):
            errors.append(
                f"F2 U1a source-contract mutation {label} findings were "
                f"{findings!r}, expected one {expected_prefix!r}")

    enum_lookup_anchor = "symbol_ref_same(group.enum_symbol, enum_symbol)"
    enum_fallback_mutations = (
        ("canonical payload fallback",
         enum_lookup_anchor + " ||\n"
         "           symbol_ref_canonical_payload(group.enum_symbol) ==\n"
         "               symbol_ref_canonical_payload(enum_symbol)",
         "F2 U1a resolver canonical payload call escaped function allowlist"),
        ("raw SymbolRef fallback",
         enum_lookup_anchor + " || group.enum_symbol == enum_symbol",
         "F2 U1a resolver used raw SymbolRef equality"),
    )
    for label, replacement, expected in enum_fallback_mutations:
        count += 1
        mutated, mutation_error = _f0_mutate_function_once(
            resolver_source, "enum_variant_constructors",
            enum_lookup_anchor, replacement)
        if mutation_error:
            errors.append(
                f"F2 U1a source-contract mutation enum {label}: "
                f"{mutation_error}")
            continue
        assert mutated is not None
        findings = resolver_identity_u1a_contract_errors(
            mutated, infer_ctx_source)
        if findings != [expected]:
            errors.append(
                f"F2 U1a source-contract mutation enum {label} findings were "
                f"{findings!r}, expected only {expected!r}")

    count += 1
    anchor = "if symbol_ref_same(existing.symbol, candidate.symbol) {"
    injected = (
        "if symbol_ref_canonical_payload(existing.symbol) == "
        "symbol_ref_canonical_payload(candidate.symbol) ||\n"
        "                   symbol_ref_same(existing.symbol, candidate.symbol) {")
    if resolver_source.count(anchor) != 1:
        errors.append("F2 U1a diagnostic-decision mutation anchor missing")
    else:
        mutated = resolver_source.replace(anchor, injected, 1)
        findings = resolver_identity_u1a_contract_errors(
            mutated, infer_ctx_source)
        expected = (
            "F2 U1a resolver canonical payload call escaped function allowlist")
        if findings != [expected]:
            errors.append(
                f"F2 U1a diagnostic-decision mutation findings were "
                f"{findings!r}, expected only {expected!r}")

    if count != F2_U1A_SOURCE_CONTRACT_MUTATION_COUNT:
        errors.append(
            f"F2 U1a source-contract mutation count was {count}, expected "
            f"{F2_U1A_SOURCE_CONTRACT_MUTATION_COUNT}")
    return errors, count


def resolver_identity_u1a_scope_guard_errors(
    resolver_source: str, infer_ctx_source: str,
) -> Tuple[List[str], int]:
    guards = (
        ("CoreHIR", "\nstruct CoreHIR { nodes: Int }\n"),
        ("FlowIR", "\nstruct FlowIR { nodes: Int }\n"),
        ("RcIR", "\nstruct RcIR { nodes: Int }\n"),
        ("CalleeRef", "\nstruct CalleeRef { value: Int }\n"),
        ("source binder", "\nfn source_binder() {}\n"),
        ("member identity", "\nfn member_identity() {}\n"),
        ("single cutover", "\nfn single_namespace_cutover() {}\n"),
        ("source binder carrier", "\nstruct SourceBinder { value: Int }\n"),
    )
    errors: List[str] = []
    count = 0
    for label, suffix in guards:
        count += 1
        if not resolver_identity_u1a_contract_errors(
                resolver_source + suffix, infer_ctx_source):
            errors.append(f"F2 U1a scope guard escaped: {label}")
    if count != F2_U1A_SCOPE_GUARD_COUNT:
        errors.append(
            f"F2 U1a scope guard count was {count}, expected "
            f"{F2_U1A_SCOPE_GUARD_COUNT}")
    return errors, count


def resolver_identity_u1a_source_errors() -> List[str]:
    """Run non-authoritative U1a source contracts and scope guards."""
    try:
        resolver_source = F2_U1A_RESOLVER_PATH.read_text(encoding="utf-8")
        infer_ctx_source = F2_U1A_INFER_CTX_PATH.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read F2 U1a compiler sources: {exc}"]
    errors = resolver_identity_u1a_contract_errors(
        resolver_source, infer_ctx_source)
    if errors:
        return errors
    mutation_errors, _ = resolver_identity_u1a_source_contract_mutation_errors(
        resolver_source, infer_ctx_source)
    guard_errors, _ = resolver_identity_u1a_scope_guard_errors(
        resolver_source, infer_ctx_source)
    errors.extend(mutation_errors)
    errors.extend(guard_errors)
    return errors


def resolver_identity_u1a_source_check_errors(ring_exe: str) -> List[str]:
    """Parse/typecheck the two sources; this is not candidate behavior."""
    errors: List[str] = []
    compiler = Path(ring_exe)
    before = _sha256_file(compiler)
    environment = dict(_controlled_environment(ring_exe))
    for source_path in (F2_U1A_RESOLVER_PATH, F2_U1A_INFER_CTX_PATH):
        completed = subprocess.run(
            [ring_exe, "check", str(source_path)], cwd=REPO, env=environment,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, encoding="utf-8",
            errors="strict", check=False, timeout=120)
        if completed.returncode != 0:
            errors.append(
                f"pinned Ring source check failed for "
                f"{display_path(source_path)}: "
                f"exit={completed.returncode} stdout={completed.stdout!r} "
                f"stderr={completed.stderr!r}")
        elif completed.stdout.strip() != "OK":
            errors.append(
                f"pinned Ring source check output drifted for "
                f"{display_path(source_path)}: stdout={completed.stdout!r}")
    if _sha256_file(compiler) != before:
        errors.append(
            "pinned Ring compiler changed across F2 U1a source checks")
    return errors


F2_U1B_PATHS = {
    "identity": REPO / "compiler" / "ir_identity.ring",
    "resolver": REPO / "compiler" / "resolver.ring",
    "types": REPO / "compiler" / "types.ring",
    "env": REPO / "compiler" / "env.ring",
    "infer_ctx": REPO / "compiler" / "infer_ctx.ring",
    "infer_register": REPO / "compiler" / "infer_register.ring",
    "hir": REPO / "compiler" / "hir.ring",
    "infer": REPO / "compiler" / "infer.ring",
    "core": REPO / "compiler" / "core_from_hir.ring",
    "core_expr": REPO / "compiler" / "core_expr.ring",
    "flow": REPO / "compiler" / "flow_lower.ring",
}


def nominal_field_u1b_contract_errors(sources: dict[str, str]) -> List[str]:
    """Cheap U1b source relations; candidate behavior remains external."""
    errors: List[str] = []
    struct_field_fields, field_error = _f0_struct_fields(
        sources["types"], "StructField")
    if field_error:
        errors.append(field_error)
    elif struct_field_fields is not None and [
            name for _, name in struct_field_fields] != [
                "name", "ty", "is_pub", "field_ref", "field_index", "span"]:
        errors.append("F2 U1b StructField identity/span inventory drifted")
    struct_def_fields, def_error = _f0_struct_fields(
        sources["env"], "StructDef")
    if def_error:
        errors.append(def_error)
    elif struct_def_fields is not None and [
            name for _, name in struct_def_fields] != [
                "name", "owner_ref", "type_params", "type_param_vars",
                "fields", "derive_attrs", "derived_provider_plan",
                "resource_storage_parameter_ordinals", "is_extern"]:
        errors.append("F2 U1b StructDef owner inventory drifted")
    registered_fields, registered_error = _f0_struct_fields(
        sources["identity"], "RegisteredNominalRef")
    if registered_error:
        errors.append(registered_error)
    elif registered_fields is not None and [
            name for _, name in registered_fields] != ["symbol", "display_name"]:
        errors.append("F2 U1b registered nominal inventory drifted")
    nominal_fields, nominal_error = _f0_struct_fields(
        sources["identity"], "NominalFieldRef")
    if nominal_error:
        errors.append(nominal_error)
    elif nominal_fields is not None and [
            name for _, name in nominal_fields] != [
                "owner", "member", "field_index", "field_name"]:
        errors.append("F2 U1b nominal field inventory drifted")

    required_relations = (
        ("identity", "make_registered_nominal_ref",
         "display_name == \"\""),
        ("identity", "make_nominal_field_ref",
         "symbol_ref_origin_module_key(owner) !="),
        ("identity", "make_nominal_field_ref",
         "symbol_ref_canonical_payload(member) !="),
        ("identity", "make_nominal_field_ref",
         '"${symbol_ref_canonical_payload(owner)}::${field_name}"'),
        ("identity", "make_nominal_field_ref",
         "symbol_ref_declaration_site_path(member) !="),
        ("identity", "make_nominal_field_ref",
         '"${symbol_ref_declaration_site_path(owner)}|field:${field_index}|kind:struct-field"'),
        ("resolver", "collect_struct_identity_fact", "none, field_index)"),
        ("resolver", "resolve_namespace_plan",
         "append_struct_identity_fact(fact, struct_identities)"),
        ("infer_ctx", "install_struct_identity_ledger",
         "for existing in ctx.struct_identity_unconsumed {\n"
         "                if existing.frame_index == fact.frame_index"),
        ("infer_ctx", "peek_struct_identity_fact",
         'none => panic("struct identity ledger: missing declaration fact")'),
        ("infer_ctx", "commit_struct_identity_fact",
         'panic("struct identity ledger: commit fact mismatch")'),
        ("infer_ctx", "peek_struct_identity_completion",
         'panic("struct identity ledger: duplicate pending completion")'),
        ("infer_ctx", "commit_struct_identity_completion",
         'panic("struct identity ledger: completion commit mismatch")'),
        ("infer_ctx", "close_struct_identity_ledger",
         "ctx.struct_identity_unconsumed.len() != 0"),
        ("infer_ctx", "apply_project_namespace_binding",
         "registered_nominal_ref_symbol(def.owner_ref)"),
        ("infer_register", "complete_struct_fields",
         "field_ref: field_identity.field_ref"),
        ("infer_register", "complete_struct_fields",
         "peek_struct_identity_completion("),
        ("infer_register", "complete_struct_fields",
         "commit_struct_identity_completion(ctx, identity)"),
        ("infer_register", "preregister_struct",
         "peek_struct_identity_fact("),
        ("infer_register", "preregister_struct",
         "commit_struct_identity_fact(ctx, identity, true)"),
        ("infer_register", "register_extern_type_common",
         "commit_struct_identity_fact(ctx, identity, false)"),
        ("infer_register", "complete_struct_fields",
         "resolved_fields.push(StructField {"),
        ("hir", "validate_hir_field_access_kind",
         "registered_nominal_ref_symbol(owner_ref)"),
        ("hir", "validate_hir_field_access_kind",
         "field != nominal_field_ref_name(field_ref)"),
        ("hir", "validate_hir_field_access_kind",
         "Type::StructType { name, .. }"),
        ("hir", "validate_hir_field_access_kind",
         "if name != registered_nominal_ref_display_name(owner_ref)"),
        ("hir", "validate_hir_field_access_kind",
         'panic("HIR identity: ErrorRecovery field access reached successful HIR")'),
        ("infer", "infer_field_access", "field_ref: found_field.field_ref"),
        ("infer", "infer_field_access", "field_index: found_field.field_index"),
        ("infer", "infer_field_access",
         "access_kind = HFieldAccessKind::NominalField {"),
        ("infer", "infer_field_access", "owner_ref: struct_def.owner_ref"),
        ("infer", "infer_struct_lit", "owner_ref: struct_def.owner_ref"),
        ("core", "producer_record_type",
         "registered_nominal_ref_symbol(def.owner_ref)"),
        ("core", "producer_record_type",
         "make_nominal_flow_field_identity(field.field_ref)"),
        ("core", "producer_record_type",
         "def.resource_storage_parameter_ordinals"),
        ("core_expr", "make_core_nominal_field",
         "CoreFieldRefValue::NominalFieldValue(value)"),
        ("flow", "flow_field",
         "make_nominal_flow_field_identity(core_field_ref_nominal(value))"),
    )
    for source_name, function_name, token in required_relations:
        _f2_u1a_require_function_token(
            sources[source_name], source_name, function_name, token, errors)

    for source_name, function_name, ordered_tokens in (
        ("infer_register", "preregister_struct", (
            "peek_struct_identity_fact(", "let def = StructDef {",
            "commit_struct_identity_fact(ctx, identity, true)",
            "ctx.env.types.structs.insert(name, def)")),
        ("infer_register", "register_extern_type_common", (
            "peek_struct_identity_fact(", "let def = StructDef {",
            "commit_struct_identity_fact(ctx, identity, false)",
            "ctx.env.types.extern_structs.insert(name, def)")),
        ("infer_register", "complete_struct_fields", (
            "peek_struct_identity_completion(",
            "let mut resolved_fields: List<StructField> = []",
            "commit_struct_identity_completion(ctx, identity)",
            "committed_def.fields = resolved_fields")),
    ):
        body, body_error = extract_ring_function_body(
            sources[source_name], function_name)
        if body_error:
            errors.append(body_error)
            continue
        positions = [body.find(token) for token in ordered_tokens]
        if any(position < 0 for position in positions) or positions != sorted(positions):
            errors.append(
                f"F2 U1b {function_name} atomic order drifted")

    hir_masked = mask_ring_strings_and_comments(sources["hir"])
    for token in (
            "pub enum HFieldAccessKind", "NominalField { owner_ref:",
            "RecordField", "TupleField", "Method", "ErrorRecovery",
            "owner_ref: RegisteredNominalRef", "field_ref: NominalFieldRef",
            "field_index: Int"):
        if token not in sources["hir"]:
            errors.append(f"F2 U1b HIR schema misses {token!r}")
    if re.search(r"StructType\s*\{[^}\n]*owner_ref", sources["types"]):
        errors.append("F2 U1b leaked owner identity into Type::StructType")
    if "HFieldAccessKind::ErrorRecovery" not in hir_masked:
        errors.append("F2 U1b successful-HIR ErrorRecovery rejection drifted")
    for forbidden in (
            "take_struct_identity_fact", "take_struct_identity_completion",
            "stage_struct_identity_completion", "def.fields.push("):
        if forbidden in sources["infer_ctx"] or forbidden in sources["infer_register"]:
            errors.append(f"F2 U1b retained non-atomic ledger path {forbidden!r}")
    return errors


F2_U1B_SOURCE_CONTRACT_MUTATIONS = (
    ("identity", "make_nominal_field_ref",
     "symbol_ref_origin_module_key(owner) !=", "false &&"),
    ("identity", "make_nominal_field_ref",
     "symbol_ref_canonical_payload(member) !=", "false &&"),
    ("identity", "make_nominal_field_ref",
     'symbol_ref_declaration_site_path(member) !=', "false &&"),
    ("resolver", "collect_struct_identity_fact", "none, field_index)",
     "none, 0)"),
    ("resolver", "resolve_namespace_plan",
     "append_struct_identity_fact(fact, struct_identities)",
     "discard_struct_identity_fact(fact)"),
    ("infer_ctx", "install_struct_identity_ledger",
     "for existing in ctx.struct_identity_unconsumed {\n"
     "                if existing.frame_index == fact.frame_index",
     "for existing in ctx.struct_identity_unconsumed {\n"
     "                if false"),
    ("infer_ctx", "peek_struct_identity_fact",
     'none => panic("struct identity ledger: missing declaration fact")',
     "none => StructIdentityFact {}"),
    ("infer_ctx", "commit_struct_identity_fact",
     'panic("struct identity ledger: commit fact mismatch")', "{}"),
    ("infer_register", "complete_struct_fields",
     "field_ref: field_identity.field_ref",
     "field_ref: identity.fields.get(0).unwrap().field_ref"),
    ("infer_register", "complete_struct_fields",
     "peek_struct_identity_completion(",
     "early_commit_struct_identity_completion("),
    ("infer_register", "preregister_struct",
     "peek_struct_identity_fact(", "early_commit_struct_identity_fact("),
    ("infer_register", "complete_struct_fields",
     "resolved_fields.push(StructField {",
     "committed_def.fields.push(StructField {"),
    ("hir", "validate_hir_field_access_kind",
     "field != nominal_field_ref_name(field_ref)", "false"),
    ("hir", "validate_hir_field_access_kind",
     "if name != registered_nominal_ref_display_name(owner_ref)",
     "if false"),
    ("infer", "infer_field_access", "field_ref: found_field.field_ref",
     "field_ref: missing_field_ref"),
    ("infer", "infer_field_access",
     "access_kind = HFieldAccessKind::NominalField {",
     "access_kind = HFieldAccessKind::RecordField"),
    ("infer", "infer_field_access", "owner_ref: struct_def.owner_ref",
     "owner_ref: wrong_owner_ref"),
    ("infer", "infer_struct_lit", "owner_ref: struct_def.owner_ref",
     "owner_ref: wrong_owner_ref"),
    ("core", "producer_record_type",
     "make_nominal_flow_field_identity(field.field_ref)",
     "make_nominal_flow_field_identity(def.fields.get(0).unwrap().field_ref)"),
    ("flow", "flow_field",
     "make_nominal_flow_field_identity(core_field_ref_nominal(value))",
     "make_path_flow_field_identity(core_field_ref_record_path(value))"),
)


def nominal_field_u1b_source_errors() -> List[str]:
    sources: dict[str, str] = {}
    try:
        for name, path in F2_U1B_PATHS.items():
            sources[name] = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read F2 U1b compiler sources: {exc}"]
    errors = nominal_field_u1b_contract_errors(sources)
    if errors:
        return errors
    count = 0
    for source_name, function_name, anchor, replacement in (
            F2_U1B_SOURCE_CONTRACT_MUTATIONS):
        count += 1
        mutated_source, mutation_error = _f0_mutate_function_once(
            sources[source_name], function_name, anchor, replacement)
        if mutation_error:
            errors.append(
                f"F2 U1b source mutation {source_name}.{function_name}: "
                f"{mutation_error}")
            continue
        mutated = dict(sources)
        mutated[source_name] = mutated_source or ""
        if not nominal_field_u1b_contract_errors(mutated):
            errors.append(
                f"F2 U1b source mutation escaped: "
                f"{source_name}.{function_name} {anchor!r}")
    if count != F2_U1B_SOURCE_CONTRACT_MUTATION_COUNT:
        errors.append(
            f"F2 U1b source mutation count was {count}, expected "
            f"{F2_U1B_SOURCE_CONTRACT_MUTATION_COUNT}")
    return errors


def nominal_field_u1b_source_check_errors(ring_exe: str) -> List[str]:
    errors: List[str] = []
    compiler = Path(ring_exe)
    before = _sha256_file(compiler)
    environment = dict(_controlled_environment(ring_exe))
    for source_path in (F2_U1B_PATHS["identity"], F2_U1B_PATHS["hir"]):
        error = _f1_run_ring_check(ring_exe, source_path, environment)
        if error:
            errors.append(error)
    if _sha256_file(compiler) != before:
        errors.append("pinned Ring compiler changed across F2 U1b checks")
    return errors


F2_TRAIT_METHOD_IDENTITY_PATHS = {
    "identity": REPO / "compiler" / "ir_identity.ring",
    "resolver": REPO / "compiler" / "resolver.ring",
    "ctx": REPO / "compiler" / "infer_ctx.ring",
    "env": REPO / "compiler" / "env.ring",
    "register": REPO / "compiler" / "infer_register.ring",
    "builtins": REPO / "compiler" / "builtins.ring",
    "hir": REPO / "compiler" / "hir.ring",
    "decl": REPO / "compiler" / "infer_decl.ring",
    "andor": REPO / "compiler" / "andor_lower.ring",
    "dict": REPO / "compiler" / "dict_lower.ring",
    "codegen": REPO / "compiler" / "codegen_c_expr.ring",
}
F2_TRAIT_METHOD_IDENTITY_MUTATION_COUNT = 42


def _trait_method_function_body(
    sources: Mapping[str, str], source_name: str, function_name: str,
    errors: List[str],
) -> str:
    body, body_error = _f0_function_body(
        sources[source_name], function_name)
    if body_error:
        errors.append(body_error)
        return ""
    assert body is not None
    return body


def trait_method_identity_u1c_contract_errors(
    sources: Mapping[str, str],
) -> List[str]:
    """Exact trait declarations; candidate behavior remains an external gate."""
    errors: List[str] = []
    identity = sources["identity"]
    resolver = sources["resolver"]
    ctx = sources["ctx"]
    env = sources["env"]
    register = sources["register"]
    builtins = sources["builtins"]
    hir = sources["hir"]
    decl = sources["decl"]
    andor = sources["andor"]
    dict_source = sources["dict"]

    for struct_name, expected_fields in (
        ("RegisteredTraitRef", ["symbol", "display_name"]),
        ("TraitMethodRef", [
            "trait_symbol", "member_symbol", "source_member_index",
            "callable_slot_index", "method_name"]),
    ):
        fields, field_error = _f0_struct_fields(identity, struct_name)
        if field_error:
            errors.append(field_error)
        elif fields is not None:
            if [name for _, name in fields] != expected_fields:
                errors.append(
                    f"trait identity {struct_name} field inventory drifted")
            if any(is_public for is_public, _ in fields):
                errors.append(
                    f"trait identity {struct_name} exposes forgeable fields")

    fact_fields, fact_error = _f0_struct_fields(
        resolver, "TraitIdentityFact")
    if fact_error:
        errors.append(fact_error)
    elif fact_fields is not None:
        if [name for _, name in fact_fields] != [
                "file_key", "frame_index", "decl_index", "owner_ref",
                "methods", "assoc_members"]:
            errors.append("trait identity fact inventory drifted")
        if not all(is_public for is_public, _ in fact_fields):
            errors.append("trait identity fact is not transportable")

    registered_body = _trait_method_function_body(
        sources, "identity", "make_registered_trait_ref", errors)
    for token in (
        'display_name == ""',
        "symbol_ref_namespace_kind(symbol), namespace_trait()",
        "RegisteredTraitRef { symbol: symbol, display_name: display_name }",
    ):
        if token not in registered_body:
            errors.append(
                f"RegisteredTraitRef constructor misses relation {token!r}")

    method_body = _trait_method_function_body(
        sources, "identity", "make_trait_method_ref", errors)
    for token in (
        "source_member_index < 0", "callable_slot_index < 0",
        "source_member_index < callable_slot_index",
        'method_name == ""',
        "symbol_ref_namespace_kind(trait_symbol), namespace_trait()",
        "symbol_ref_origin_module_key(trait_symbol), namespace_member()",
        "symbol_ref_origin_module_key(trait_symbol) !=",
        "symbol_ref_namespace_kind(member_symbol), namespace_member()",
        "symbol_ref_canonical_payload(member_symbol) !=",
        "symbol_ref_declaration_site_path(member_symbol) !=",
        "source_member_index: source_member_index",
        "callable_slot_index: callable_slot_index",
        "method_name: method_name",
    ):
        if token not in method_body:
            errors.append(
                f"TraitMethodRef constructor misses relation {token!r}")
    same_body = _trait_method_function_body(
        sources, "identity", "trait_method_ref_same", errors)
    for token in (
        "symbol_ref_same(left.trait_symbol, right.trait_symbol)",
        "symbol_ref_same(left.member_symbol, right.member_symbol)",
        "left.source_member_index == right.source_member_index",
        "left.callable_slot_index == right.callable_slot_index",
        "left.method_name == right.method_name",
    ):
        if token not in same_body:
            errors.append(f"TraitMethodRef equality misses {token!r}")

    for container in ("ModuleNamespaceCensus", "ResolvedNamespacePlan"):
        fields, field_error = _f0_struct_fields(resolver, container)
        if field_error:
            errors.append(field_error)
        elif fields is not None and "trait_identities" not in [
                name for _, name in fields]:
            errors.append(f"{container} loses exact trait facts")

    collect_body = _trait_method_function_body(
        sources, "resolver", "collect_trait_identity_fact", errors)
    for token in (
        "for source_member_index in 0..methods.len()",
        "some(Decl::Fn { name, .. })",
        "owner_ref, source_member_index,",
        "callable_slot_index, name",
        "callable_slot_index = callable_slot_index + 1",
        "append_trait_identity_fact(TraitIdentityFact {",
    ):
        if token not in collect_body:
            errors.append(f"trait resolver producer misses {token!r}")
    append_body = _trait_method_function_body(
        sources, "resolver", "append_trait_identity_fact", errors)
    if not all(token in append_body for token in (
            "existing.file_key == fact.file_key",
            "existing.frame_index == fact.frame_index",
            "existing.decl_index == fact.decl_index",
            "duplicate trait identity site")):
        errors.append("trait resolver fact dedupe is not exact-site")
    seed_body = _trait_method_function_body(
        sources, "resolver", "collect_decl_seed", errors)
    if not all(token in seed_body for token in (
            "Decl::Trait { name, methods, is_pub, .. }",
            "collect_trait_identity_fact(",
            "frame, decl_index, owner_ref, methods, trait_identities")):
        errors.append("trait resolver seed does not own method production")
    resolve_body = _trait_method_function_body(
        sources, "resolver", "resolve_namespace_plan", errors)
    if "append_trait_identity_fact(fact, trait_identities)" not in resolve_body:
        errors.append("resolved plan bypasses exact trait fact dedupe")
    if resolver.count("make_trait_method_ref(") != 1:
        errors.append("resolver TraitMethodRef producer count drifted")

    install_body = _trait_method_function_body(
        sources, "ctx", "install_struct_identity_ledger", errors)
    for token in (
        "ctx.trait_identity_unconsumed.len() != 0",
        "for fact in plan.trait_identities",
        "trait_identity_site_same(existing, fact)",
        "ctx.trait_identity_unconsumed.push(fact)",
    ):
        if token not in install_body:
            errors.append(f"trait registration ledger misses {token!r}")
    site_body = _trait_method_function_body(
        sources, "ctx", "trait_identity_site_same", errors)
    if not all(token in site_body for token in (
            "left.file_key == right.file_key",
            "left.frame_index == right.frame_index",
            "left.decl_index == right.decl_index")):
        errors.append("trait registration site equality is incomplete")
    peek_body = _trait_method_function_body(
        sources, "ctx", "peek_trait_identity_fact", errors)
    for token in (
        "fact.file_key == file_key", "fact.frame_index == frame_index",
        "fact.decl_index == decl_index", "fact.methods.len() != method_count",
        "missing declaration fact",
    ):
        if token not in peek_body:
            errors.append(f"trait registration peek misses {token!r}")
    commit_body = _trait_method_function_body(
        sources, "ctx", "commit_trait_identity_fact", errors)
    if commit_body.count("trait_identity_fact_same(existing, fact)") != 1 or (
            "if matches != 1" not in commit_body or
            "ctx.trait_identity_unconsumed = remaining" not in commit_body):
        errors.append("trait registration commit is not consume-once")
    close_body = _trait_method_function_body(
        sources, "ctx", "close_struct_identity_ledger", errors)
    if ("ctx.trait_identity_unconsumed.len() != 0" not in close_body or
            "ctx.trait_identity_unconsumed = []" not in close_body):
        errors.append("trait registration ledger does not close")

    hydration_body = _trait_method_function_body(
        sources, "ctx", "apply_project_namespace_binding", errors)
    for token in (
        "binding.symbol,\n                        registered_trait_ref_symbol(def.owner_ref)",
        "registered_trait_ref_display_name(def.owner_ref) !=",
        "def.name || def.name != canonical_payload",
        "ctx.env.trait_reg.traits.insert(binding.exposed_name, def)",
    ):
        if token not in hydration_body:
            errors.append(f"trait project hydration misses {token!r}")

    method_def_fields, method_def_error = _f0_struct_fields(
        env, "TraitMethodDef")
    if method_def_error:
        errors.append(method_def_error)
    elif method_def_fields is not None and [
            name for _, name in method_def_fields] != [
                "name", "method_ref", "ty", "has_default",
                "param_mutabilities", "method_type_params"]:
        errors.append("TraitMethodDef exact ref inventory drifted")
    trait_def_fields, trait_def_error = _f0_struct_fields(env, "TraitDef")
    if trait_def_error:
        errors.append(trait_def_error)
    elif trait_def_fields is not None and [
            name for _, name in trait_def_fields] != [
                "name", "owner_ref", "type_params", "type_param_vars",
                "methods", "supertraits", "assoc_types", "contract"]:
        errors.append("TraitDef registered owner inventory drifted")

    register_body = _trait_method_function_body(
        sources, "register", "register_trait", errors)
    register_tokens = (
        "let identity = peek_trait_identity_fact(\n        ctx, decl_index, method_count, assoc_count)",
        "identity.methods.get(callable_slot_index)",
        "trait_method_ref_trait(method_ref), identity.owner_ref",
        "trait_method_ref_source_member_index(method_ref) !=",
        "trait_method_ref_callable_slot_index(method_ref) !=",
        "trait_method_ref_name(method_ref) != identity_method_name",
        "method_ref: method_ref",
        "let registered_owner = make_registered_trait_ref(identity.owner_ref, name)",
        "contract: contract",
        "commit_trait_identity_fact(ctx, identity)",
    )
    for token in register_tokens:
        if token not in register_body:
            errors.append(f"trait registration consumer misses {token!r}")
    if register_body.count("commit_trait_identity_fact(ctx, identity)") != 1:
        errors.append("trait registration does not commit exactly once")
    peek_at = register_body.find("peek_trait_identity_fact(")
    commit_at = register_body.find("commit_trait_identity_fact(")
    semantic_at = register_body.find("validate_type_param_bound_shapes(")
    publish_at = register_body.find("ctx.env.trait_reg.traits.insert(")
    if min(peek_at, commit_at, semantic_at, publish_at) < 0 or not (
            peek_at < commit_at < semantic_at < publish_at):
        errors.append("trait registration atomic order drifted")

    builtin_body = _trait_method_function_body(
        sources, "builtins", "builtin_trait_symbol", errors)
    if not all(token in builtin_body for token in (
            '"$builtin"', "namespace_trait()", '"builtin:trait:${name}"')):
        errors.append("builtin trait identity domain drifted")
    builtin_method_body = _trait_method_function_body(
        sources, "builtins", "builtin_trait_method", errors)
    if not all(token in builtin_method_body for token in (
            "source_member_index != callable_slot_index",
            "source/slot ordering drifted", "make_trait_method_ref(")):
        errors.append("builtin trait method bypasses typed relation")
    if builtins.count("install_builtin_trait_contract(") != 7:
        errors.append("builtin registered trait census drifted")

    hmethod_fields, hmethod_error = _f0_struct_fields(hir, "HTraitMethod")
    if hmethod_error:
        errors.append(hmethod_error)
    elif hmethod_fields is not None and [
            name for _, name in hmethod_fields] != [
                "name", "method_ref", "params", "return_type", "effects",
                "has_default", "body"]:
        errors.append("HTraitMethod exact ref inventory drifted")
    validate_body = _trait_method_function_body(
        sources, "hir", "validate_hir_decls", errors)
    for token in (
        "registered_trait_ref_display_name(owner_ref) != name",
        "let mut previous_source_member_index = -1",
        "trait_method_ref_source_member_index(method.method_ref)",
        "trait_method_ref_trait(method.method_ref)",
        "registered_trait_ref_symbol(owner_ref)",
        "trait_method_ref_callable_slot_index(",
        "method.method_ref) != method_index",
        "source_member_index < method_index",
        "source_member_index <= previous_source_member_index",
        "previous_source_member_index = source_member_index",
        "trait_method_ref_name(method.method_ref) != method.name",
    ):
        if token not in validate_body:
            errors.append(f"HIR trait relation validator misses {token!r}")

    decl_body = _trait_method_function_body(
        sources, "decl", "check_trait_decl", errors)
    for token in (
        "for method_index in 0..trait_def.methods.len()",
        "trait_method_ref_source_member_index(m.method_ref)",
        "trait_method_ref_trait(m.method_ref)",
        "registered_trait_ref_symbol(trait_def.owner_ref)",
        "trait_method_ref_callable_slot_index(m.method_ref) != method_index",
        "source_member_index < method_index",
        "trait_method_ref_name(m.method_ref) != m.name",
        "ast_methods.get(source_member_index)",
        "Decl::Fn { name: source_name, is_abstract, .. }",
        "source_name != m.name || m.has_default == is_abstract",
        "source_param.name", "source_param.is_mutable",
        "method_ref: m.method_ref", "owner_ref: trait_def.owner_ref"):
        if token not in decl_body:
            errors.append(f"typed HIR trait transport misses {token!r}")
    if "find_ast_fn_by_name" in decl:
        errors.append(
            "typed HIR trait transport retained fallback 'find_ast_fn_by_name'")
    for forbidden in (
            "methods.find(", "ast_methods.filter(", '"p${pi.to_str()}"'):
        if forbidden in decl_body:
            errors.append(
                f"typed HIR trait transport retained fallback {forbidden!r}")
    for source_name, function_name in (("andor", "al_decl"), ("dict", "dl_decl")):
        visitor_body = _trait_method_function_body(
            sources, source_name, function_name, errors)
        for token in (
            "owner_ref: trait_owner_ref", "method_ref: tm.method_ref"):
            if token not in visitor_body:
                errors.append(
                    f"{source_name} trait transport misses {token!r}")

    combined_nonproducers = "\n".join(
        sources[name] for name in (
            "ctx", "env", "hir", "decl", "andor", "dict", "codegen"))
    if "make_trait_method_ref(" in combined_nonproducers:
        errors.append("downstream stage remints TraitMethodRef")
    for token in (
            "TraitMethodRef", "RegisteredTraitRef",
            "trait_method_ref_", "registered_trait_ref_"):
        if token in sources["codegen"]:
            errors.append(f"backend semantically reads trait identity {token!r}")
    for source_name in ("ctx", "register", "hir", "decl", "andor", "dict"):
        masked = mask_ring_strings_and_comments(sources[source_name])
        if re.search(
                r"Map\s*<\s*Str\s*,\s*(?:TraitMethodRef|RegisteredTraitRef)\s*>",
                masked):
            errors.append(f"{source_name} gained a trait identity side map")
    return errors


def trait_method_identity_u1c_mutation_errors(
    sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    mutations = (
        ("registered owner domain", "identity", "make_registered_trait_ref",
         "symbol_ref_namespace_kind(symbol), namespace_trait()",
         "symbol_ref_namespace_kind(symbol), namespace_nominal()"),
        ("registered display", "identity", "make_registered_trait_ref",
         'display_name == ""', "false"),
        ("method owner domain", "identity", "make_trait_method_ref",
         "symbol_ref_namespace_kind(trait_symbol), namespace_trait()",
         "symbol_ref_namespace_kind(trait_symbol), namespace_nominal()"),
        ("source before callable slot", "identity", "make_trait_method_ref",
         "source_member_index < callable_slot_index", "false"),
        ("member production domain", "identity", "make_trait_method_ref",
         "symbol_ref_origin_module_key(trait_symbol), namespace_member()",
         "symbol_ref_origin_module_key(trait_symbol), namespace_value()"),
        ("member origin module", "identity", "make_trait_method_ref",
         "symbol_ref_origin_module_key(trait_symbol) !=",
         "false &&"),
        ("member validation domain", "identity", "make_trait_method_ref",
         "symbol_ref_namespace_kind(member_symbol), namespace_member()",
         "symbol_ref_namespace_kind(member_symbol), namespace_value()"),
        ("member payload", "identity", "make_trait_method_ref",
         "symbol_ref_canonical_payload(member_symbol) !=", "false &&"),
        ("member path", "identity", "make_trait_method_ref",
         "symbol_ref_declaration_site_path(member_symbol) !=", "false &&"),
        ("source member index", "identity", "make_trait_method_ref",
         "source_member_index: source_member_index",
         "source_member_index: 0"),
        ("callable slot index", "identity", "make_trait_method_ref",
         "callable_slot_index: callable_slot_index",
         "callable_slot_index: 0"),
        ("method name", "identity", "make_trait_method_ref",
         "method_name: method_name", 'method_name: ""'),
        ("member equality", "identity", "trait_method_ref_same",
         "symbol_ref_same(left.member_symbol, right.member_symbol)", "true"),
        ("resolver exact-site frame", "resolver", "append_trait_identity_fact",
         "existing.frame_index == fact.frame_index", "true"),
        ("resolver assoc/method order", "resolver", "collect_trait_identity_fact",
         "owner_ref, source_member_index,\n                    callable_slot_index, name",
         "owner_ref, callable_slot_index,\n                    source_member_index, name"),
        ("resolver slot progression", "resolver", "collect_trait_identity_fact",
         "callable_slot_index = callable_slot_index + 1",
         "callable_slot_index = callable_slot_index + 0"),
        ("resolved fact dedupe", "resolver", "resolve_namespace_plan",
         "append_trait_identity_fact(fact, trait_identities)",
         "trait_identities.push(fact)"),
        ("ledger fact census", "ctx", "install_struct_identity_ledger",
         "for fact in plan.trait_identities", "for fact in []"),
        ("ledger site declaration", "ctx", "trait_identity_site_same",
         "left.decl_index == right.decl_index", "true"),
        ("ledger peek frame", "ctx", "peek_trait_identity_fact",
         "fact.frame_index == frame_index", "true"),
        ("zero consume", "register", "register_trait",
         "commit_trait_identity_fact(ctx, identity)", "{}"),
        ("double consume", "register", "register_trait",
         "commit_trait_identity_fact(ctx, identity)",
         "commit_trait_identity_fact(ctx, identity)\n    commit_trait_identity_fact(ctx, identity)"),
        ("consume after semantic validation", "register", "register_trait",
         "commit_trait_identity_fact(ctx, identity)\n    validate_type_param_bound_shapes(\n        ctx, type_params, BoundShapeContext::OrdinaryBound, span)",
         "validate_type_param_bound_shapes(\n        ctx, type_params, BoundShapeContext::OrdinaryBound, span)\n    commit_trait_identity_fact(ctx, identity)"),
        ("ledger close", "ctx", "close_struct_identity_ledger",
         "ctx.trait_identity_unconsumed.len() != 0", "false"),
        ("hydration binding symbol", "ctx", "apply_project_namespace_binding",
         "binding.symbol,\n                        registered_trait_ref_symbol(def.owner_ref)",
         "registered_trait_ref_symbol(def.owner_ref),\n                        registered_trait_ref_symbol(def.owner_ref)"),
        ("hydration display relation", "ctx", "apply_project_namespace_binding",
         "registered_trait_ref_display_name(def.owner_ref) !=",
         "false &&"),
        ("reexport remint", "ctx", "apply_project_namespace_binding",
         "ctx.env.trait_reg.traits.insert(binding.exposed_name, def)",
         "ctx.env.trait_reg.traits.insert(binding.exposed_name, remint_trait(def))"),
        ("registration owner relation", "register", "register_trait",
         "trait_method_ref_trait(method_ref), identity.owner_ref",
         "identity.owner_ref, identity.owner_ref"),
        ("registration source site", "register", "register_trait",
         "trait_method_ref_source_member_index(method_ref) !=",
         "false &&"),
        ("builtin/source domain", "builtins", "builtin_trait_symbol",
         '"$builtin"', '"$single$"'),
        ("builtin source/slot mismatch", "builtins", "builtin_trait_method",
         "source_member_index != callable_slot_index", "false"),
        ("trait HIR name scan", "decl", "check_trait_decl",
         "ast_methods.get(source_member_index)",
         "find_ast_fn_by_name(ast_methods, m.name)"),
        ("trait HIR wrong index", "decl", "check_trait_decl",
         "ast_methods.get(source_member_index)",
         "ast_methods.get(method_index)"),
        ("trait HIR filtered index", "decl", "check_trait_decl",
         "ast_methods.get(source_member_index)",
         "ast_methods.filter(fn(candidate) { true }).get(source_member_index)"),
        ("typed HIR transport", "decl", "check_trait_decl",
         "method_ref: m.method_ref", "method_ref: hmethods.first().unwrap().method_ref"),
        ("andor transport", "andor", "al_decl",
         "method_ref: tm.method_ref", "method_ref: new_methods.first().unwrap().method_ref"),
        ("dict transport", "dict", "dl_decl",
         "method_ref: tm.method_ref", "method_ref: new_methods.first().unwrap().method_ref"),
        ("HIR registered display", "hir", "validate_hir_decls",
         "registered_trait_ref_display_name(owner_ref) != name", "false"),
        ("HIR callable slot", "hir", "validate_hir_decls",
         "trait_method_ref_callable_slot_index(\n                            method.method_ref) != method_index",
         "false"),
        ("HIR duplicate/decreasing source", "hir", "validate_hir_decls",
         "source_member_index <= previous_source_member_index", "false"),
        ("HIR method name", "hir", "validate_hir_decls",
         "trait_method_ref_name(method.method_ref) != method.name", "false"),
        ("resolver seed method inventory", "resolver", "collect_decl_seed",
         "frame, decl_index, owner_ref, methods, trait_identities",
         "frame, decl_index, owner_ref, [], trait_identities"),
    )
    killed = 0
    for label, source_name, function_name, anchor, replacement in mutations:
        mutated_source, mutation_error = _f0_mutate_function_once(
            sources[source_name], function_name, anchor, replacement)
        if mutation_error:
            errors.append(f"trait identity mutation {label}: {mutation_error}")
            continue
        assert mutated_source is not None
        mutated = dict(sources)
        mutated[source_name] = mutated_source
        findings = trait_method_identity_u1c_contract_errors(mutated)
        if not findings:
            errors.append(f"trait identity mutation escaped: {label}")
        else:
            killed += 1
    if killed != F2_TRAIT_METHOD_IDENTITY_MUTATION_COUNT:
        errors.append(
            f"trait identity killed {killed} mutations, expected "
            f"{F2_TRAIT_METHOD_IDENTITY_MUTATION_COUNT}")
    return errors


def trait_method_identity_u1c_source_errors() -> List[str]:
    sources: dict[str, str] = {}
    try:
        for name, path in F2_TRAIT_METHOD_IDENTITY_PATHS.items():
            sources[name] = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read trait identity compiler sources: {exc}"]
    errors = trait_method_identity_u1c_contract_errors(sources)
    if errors:
        return errors
    errors.extend(trait_method_identity_u1c_mutation_errors(sources))
    return errors


def trait_method_identity_u1c_fixture_errors(ring_exe: str) -> List[str]:
    errors: List[str] = []
    compiler = Path(ring_exe).resolve(strict=True)
    compiler_before = _sha256_file(compiler)
    environment = dict(_controlled_environment(str(compiler)))
    positive = CASES_DIR / "trait_method_identity_assoc_order.ring"
    negative = CASES_DIR / "error_supertrait_assoc_predicate.ring"

    if positive not in discover_positive_cases(CASES_DIR):
        errors.append("trait identity assoc-order fixture is not runner-discovered")
    else:
        positive_error = _f1_run_ring_check(
            str(compiler), positive, environment)
        if positive_error:
            errors.append(positive_error)

    if negative not in discover_negative_cases(CASES_DIR):
        errors.append("trait identity clean-diagnostic fixture is not runner-discovered")
    else:
        try:
            completed = subprocess.run(
                [str(compiler), "check", str(negative)],
                cwd=REPO, env=environment, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, encoding="utf-8", errors="strict",
                check=False, timeout=120)
        except subprocess.TimeoutExpired:
            errors.append("trait identity clean-diagnostic parser check timed out")
        else:
            if completed.returncode == 0:
                if completed.stdout != "OK\n" or completed.stderr:
                    errors.append(
                        "trait identity pre-cutover parser output drifted: "
                        f"stdout={completed.stdout!r} stderr={completed.stderr!r}")
            else:
                contract = negative.with_suffix(".error").read_text(
                    encoding="utf-8")
                combined = (completed.stdout or "") + (completed.stderr or "")
                contract_error = error_contract_failure(contract, combined)
                if contract_error is not None:
                    errors.append(
                        "trait identity diagnostic is not clean: "
                        f"{contract_error}; output={combined[:300]!r}")
    if _sha256_file(compiler) != compiler_before:
        errors.append("pinned Ring compiler changed across trait identity fixtures")
    return errors


F2_IMPL_PROVIDER_PATHS = {
    "identity": REPO / "compiler" / "ir_identity.ring",
    "resolver": REPO / "compiler" / "resolver.ring",
    "ctx": REPO / "compiler" / "infer_ctx.ring",
    "env": REPO / "compiler" / "env.ring",
    "register": REPO / "compiler" / "infer_register.ring",
    "builtins": REPO / "compiler" / "builtins.ring",
    "derive": REPO / "compiler" / "derive.ring",
    "decl": REPO / "compiler" / "infer_decl.ring",
    "codegen": REPO / "compiler" / "codegen_c_expr.ring",
}
F2_IMPL_PROVIDER_MUTATION_COUNT = 54


def impl_provider_u1c1_contract_errors(
    sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    identity = sources["identity"]
    resolver = sources["resolver"]
    ctx = sources["ctx"]
    env = sources["env"]
    register = sources["register"]
    builtins = sources["builtins"]
    derive = sources["derive"]
    decl = sources["decl"]

    for struct_name, expected_fields in (
        ("ImplProviderKind", ["tag"]),
        ("ImplProviderRef", ["site", "kind"]),
    ):
        fields, field_error = _f0_struct_fields(identity, struct_name)
        if field_error:
            errors.append(field_error)
        elif fields is not None:
            if [name for _, name in fields] != expected_fields:
                errors.append(f"impl provider {struct_name} inventory drifted")
            if any(is_public for is_public, _ in fields):
                errors.append(f"impl provider {struct_name} exposes fields")

    provider_body = _trait_method_function_body(
        sources, "identity", "make_impl_provider_ref", errors)
    for token in (
        "path_ref_owner(site)", "path_owner_ref_is_symbol(owner)",
        "impl_provider_kind_from_tag(", "path_ref_role(site)",
        "impl_provider_kind_source()", "path_role_declaration()",
        "path_role_synthetic()", "ImplProviderRef { site: site, kind: checked_kind }",
    ):
        if token not in provider_body:
            errors.append(f"ImplProviderRef constructor misses {token!r}")
    provider_same = _trait_method_function_body(
        sources, "identity", "impl_provider_ref_same", errors)
    if not all(token in provider_same for token in (
            "path_ref_same(left.site, right.site)",
            "impl_provider_kind_same(left.kind, right.kind)")):
        errors.append("ImplProviderRef equality is incomplete")

    fact_schemas = (
        ("SourceImplProviderFact", [
            "file_key", "frame_index", "decl_index", "provider_ref",
            "methods"]),
        ("DelegateProviderFact", [
            "file_key", "frame_index", "parent_decl_index",
            "source_member_index", "parent_provider_ref", "provider_ref"]),
        ("ExplicitDerivedProviderFact", ["attr_index", "provider_ref"]),
        ("NominalDerivedProviderPlanFact", [
            "file_key", "frame_index", "decl_index",
            "implicit_provider_ref", "explicit_providers"]),
    )
    for struct_name, expected_fields in fact_schemas:
        fields, field_error = _f0_struct_fields(resolver, struct_name)
        if field_error:
            errors.append(field_error)
        elif fields is not None:
            if [name for _, name in fields] != expected_fields:
                errors.append(f"{struct_name} inventory drifted")
            if not all(is_public for is_public, _ in fields):
                errors.append(f"{struct_name} is not transportable")

    for container in ("ModuleNamespaceCensus", "ResolvedNamespacePlan"):
        fields, field_error = _f0_struct_fields(resolver, container)
        if field_error:
            errors.append(field_error)
            continue
        assert fields is not None
        names = [name for _, name in fields]
        for required in (
                "source_impl_providers", "delegate_providers",
                "nominal_derived_providers"):
            if required not in names:
                errors.append(f"{container} loses {required}")

    source_provider_body = _trait_method_function_body(
        sources, "resolver", "source_provider_ref", errors)
    for token in (
        'frame.file_key, "frame:${frame.frame_index}"',
        "path_owner_for_module_body(module_body)",
        "path_role_declaration()", "path_role_synthetic()",
        "impl_provider_kind_source()", "impl_provider_kind_derived()",
    ):
        if token not in source_provider_body:
            errors.append(f"resolver provider producer misses {token!r}")
    delegate_provider_body = _trait_method_function_body(
        sources, "resolver", "source_delegate_provider_ref", errors)
    for token in (
        '"decl:${decl_index}", "delegate:${source_member_index}"',
        "path_role_synthetic()", "impl_provider_kind_delegate()",
    ):
        if token not in delegate_provider_body:
            errors.append(f"delegate provider producer misses {token!r}")
    nominal_body = _trait_method_function_body(
        sources, "resolver", "collect_nominal_derived_provider_fact", errors)
    for token in (
        '"decl:${decl_index}", "derive:implicit"',
        "for attr_index in 0..derive_attrs.len()",
        '"decl:${decl_index}", "derive:attr:${attr_index}"',
        "attr_index: attr_index",
        "append_nominal_derived_provider_fact(",
    ):
        if token not in nominal_body:
            errors.append(f"nominal derive producer misses {token!r}")
    impl_fact_body = _trait_method_function_body(
        sources, "resolver", "collect_impl_provider_facts", errors)
    for token in (
        '"decl:${decl_index}", "impl"',
        "for source_member_index in 0..methods.len()",
        "some(Decl::Delegate { .. })",
        "parent_provider_ref: source",
        "source_delegate_provider_ref(",
    ):
        if token not in impl_fact_body:
            errors.append(f"source/delegate provider producer misses {token!r}")
    for function_name, tokens in (
        ("append_source_impl_provider_fact", (
            "existing.file_key == fact.file_key",
            "existing.frame_index == fact.frame_index",
            "existing.decl_index == fact.decl_index")),
        ("append_delegate_provider_fact", (
            "existing.file_key == fact.file_key",
            "existing.frame_index == fact.frame_index",
            "existing.parent_decl_index == fact.parent_decl_index",
            "existing.source_member_index == fact.source_member_index")),
        ("append_nominal_derived_provider_fact", (
            "existing.file_key == fact.file_key",
            "existing.frame_index == fact.frame_index",
            "existing.decl_index == fact.decl_index")),
    ):
        body = _trait_method_function_body(
            sources, "resolver", function_name, errors)
        for token in tokens:
            if token not in body:
                errors.append(f"{function_name} misses {token!r}")
    resolve_body = _trait_method_function_body(
        sources, "resolver", "resolve_namespace_plan", errors)
    for token in (
        "append_source_impl_provider_fact(fact, source_impl_providers)",
        "append_delegate_provider_fact(fact, delegate_providers)",
        "append_nominal_derived_provider_fact(",
    ):
        if token not in resolve_body:
            errors.append(f"resolved provider plan misses {token!r}")

    env_schemas = (
        ("ExplicitDerivedProviderPlan", ["attribute", "provider_ref"]),
        ("NominalDerivedProviderPlan", [
            "implicit_provider_ref", "explicit_providers"]),
        ("EnumDef", [
            "name", "owner_ref", "type_params", "type_param_vars",
            "variants", "variant_refs", "variant_field_refs",
            "derive_attrs", "derived_provider_plan", "variant_index"]),
        ("ImplEntry", [
            "trait_name", "target_type_name", "type_params",
            "type_param_vars", "predicates", "method_names", "assoc_types",
            "method_schemes", "method_refs", "method_intrinsics",
            "provider_ref", "trait_ref", "owner_ref", "delegate_plan",
            "span"]),
    )
    for struct_name, expected_fields in env_schemas:
        fields, field_error = _f0_struct_fields(env, struct_name)
        if field_error:
            errors.append(field_error)
        elif fields is not None and [
                name for _, name in fields] != expected_fields:
            errors.append(f"{struct_name} provider inventory drifted")

    for retired in (
            "MethodOrigin", "ImplOwnerState", "ProvisionalPrelude",
            "find_impl_by_origin", "impl_decl_origin", "impl_method_origin"):
        if retired in env or retired in builtins or retired in register:
            errors.append(f"retired impl provider authority returned: {retired}")

    validate_body = _trait_method_function_body(
        sources, "env", "validate_impl_entry", errors)
    for token in (
        "match (entry.trait_name, entry.trait_ref)",
        "registered_trait_ref_symbol(def.owner_ref), trait_ref",
        "match (entry.provider_ref, entry.owner_ref)",
        "entry.method_refs.len() != entry.method_schemes.len()",
        "impl owner: final owner lacks typed identity",
    ):
        if token not in validate_body:
            errors.append(f"impl provider state validator misses {token!r}")
    key_body = _trait_method_function_body(
        sources, "env", "impl_entry_exact_key_same", errors)
    for token in (
        "match (left.owner_ref, right.owner_ref)",
        "impl_owner_ref_same(a, b)",
    ):
        if token not in key_body:
            errors.append(f"impl exact owner key misses {token!r}")
    install_body = _trait_method_function_body(
        sources, "env", "install_method_core", errors)
    for token in (
        "let incoming_owner = impl_method_ref_owner(incoming)",
        "find_impl_by_provider(", "impl_owner_ref_trait(incoming_owner)",
        "impl_owner_ref_provider(incoming_owner)",
        "impl_method_ref_same(stored_ref, incoming)",
        "reg.method_index.get(target_type)",
    ):
        if token not in install_body:
            errors.append(f"method origin provider closure misses {token!r}")
    add_body = _trait_method_function_body(
        sources, "env", "add_impl", errors)
    if "impl_entry_exact_key_same(existing, entry)" not in add_body:
        errors.append("registry add_impl does not use the typed owner key")

    ledger_functions = (
        ("peek_source_impl_provider_fact", (
            "fact.frame_index == frame_index", "fact.decl_index == decl_index",
            "missing source impl fact")),
        ("commit_source_impl_provider_fact", (
            "source_impl_provider_fact_same(existing, fact)",
            "if matches != 1")),
        ("peek_delegate_provider_fact", (
            "fact.parent_decl_index == parent_decl_index",
            "fact.source_member_index == source_member_index",
            "missing delegate fact")),
        ("commit_delegate_provider_fact", (
            "delegate_provider_fact_same(existing, fact)",
            "if matches != 1")),
        ("peek_nominal_derived_provider_fact", (
            "fact.explicit_providers.len() != attr_count",
            "explicit.attr_index != index", "derive attribute order changed")),
        ("commit_nominal_derived_provider_fact", (
            "nominal_derived_provider_fact_same(existing, fact)",
            "if matches != 1")),
    )
    for function_name, tokens in ledger_functions:
        body = _trait_method_function_body(
            sources, "ctx", function_name, errors)
        for token in tokens:
            if token not in body:
                errors.append(f"{function_name} misses {token!r}")
    close_body = _trait_method_function_body(
        sources, "ctx", "close_struct_identity_ledger", errors)
    for token in (
        "ctx.source_impl_provider_unconsumed.len() != 0",
        "ctx.delegate_provider_unconsumed.len() != 0",
        "ctx.nominal_derived_provider_unconsumed.len() != 0",
    ):
        if token not in close_body:
            errors.append(f"provider ledger close misses {token!r}")

    consume_body = _trait_method_function_body(
        sources, "register", "consume_nominal_derived_provider_plan", errors)
    for token in (
        "peek_nominal_derived_provider_fact(",
        "value.attr_index != attr_index", "attribute: attribute",
        "commit_nominal_derived_provider_fact(ctx, fact)",
        "implicit_provider_ref: fact.implicit_provider_ref",
    ):
        if token not in consume_body:
            errors.append(f"nominal derive registration misses {token!r}")
    register_impl_body = _trait_method_function_body(
        sources, "register", "register_impl", errors)
    if not all(token in register_impl_body for token in (
            "peek_source_impl_provider_fact(ctx, decl_index)",
            "commit_source_impl_provider_fact(ctx, provider_fact)",
            "provider_fact.provider_ref")):
        errors.append("source impl provider is not consumed before registration")
    canonical_impl_body = _trait_method_function_body(
        sources, "register", "register_impl_canonical", errors)
    for token in (
        "provider_ref: some(provider_ref)",
        "trait_ref: resolved_trait_ref",
        "owner_ref: some(owner_ref)",
        "method_refs: exact_method_refs",
    ):
        if token not in canonical_impl_body:
            errors.append(f"source impl final owner misses {token!r}")
    for function_name in ("preregister_struct", "preregister_enum"):
        body = _trait_method_function_body(
            sources, "register", function_name, errors)
        if ("consume_nominal_derived_provider_plan(" not in body or
                "derived_provider_plan: some(derived_provider_plan)" not in body):
            errors.append(f"{function_name} loses the nominal provider plan")
    phase3_body = _trait_method_function_body(
        sources, "register", "register_phase3_delegate", errors)
    for token in (
        "peek_delegate_provider_fact(",
        "commit_delegate_provider_fact(ctx, fact)",
        "find_impl_by_provider(", "parent_provider_ref",
        "impl_provider_ref_same(",
        "fact.source_member_index != source_member_index",
        "fact.provider_ref",
    ):
        if token not in phase3_body:
            errors.append(f"delegate phase3 provider closure misses {token!r}")
    for forbidden in ("impl_decl_origin(", "find_impl_by_origin("):
        if forbidden in phase3_body:
            errors.append(f"delegate phase3 retained fallback {forbidden!r}")
    for function_name in (
            "register_nonproject_phase3_delegate",
            "register_project_phase3_delegate"):
        body = _trait_method_function_body(
            sources, "register", function_name, errors)
        if ("enter_struct_identity_child_frame(ctx, item.decl_index)" not in body or
                "exit_struct_identity_frame(ctx)" not in body):
            errors.append(f"{function_name} does not pair provider frames")

    builtin_provider = _trait_method_function_body(
        sources, "builtins", "builtin_impl_provider", errors)
    if not all(token in builtin_provider for token in (
            '"$builtin", "builtin:impl-providers"',
            "[ordinal.to_str()]", "path_role_synthetic()",
            "impl_provider_kind_builtin()")):
        errors.append("builtin impl provider domain drifted")
    builtin_masked = mask_ring_strings_and_comments(builtins)
    site_matches = re.findall(
        r"\bstruct\s+BuiltinImplProviderSite\s*\{\s*tag\s*:\s*Int\s*\}",
        builtin_masked)
    if len(site_matches) != 1 or re.search(
            r"\bpub\s+struct\s+BuiltinImplProviderSite\b",
            builtin_masked):
        errors.append("builtin provider site private inventory drifted")
    ordinals, ordinal_error = _f0_int_list(
        builtins, "BUILTIN_PROVIDER_ORDINALS")
    if ordinal_error:
        errors.append(ordinal_error)
    elif ordinals != list(range(13)):
        errors.append(f"builtin provider ordinal table drifted: {ordinals!r}")
    site_body = _trait_method_function_body(
        sources, "builtins", "builtin_impl_provider_site_from_tag", errors)
    for token in (
        "tag < 0 || tag >= BUILTIN_PROVIDER_SITE_COUNT",
        "BUILTIN_PROVIDER_ORDINALS.len() != BUILTIN_PROVIDER_SITE_COUNT",
        "ordinal != expected", "seen.contains(ordinal)",
        "BuiltinImplProviderSite { tag: tag }",
    ):
        if token not in site_body:
            errors.append(f"builtin provider site validator misses {token!r}")
    for forbidden in (
            "trait_name", "target_type_name", "origin", "method_name",
            "provider_path"):
        if forbidden in builtin_provider:
            errors.append(
                f"builtin provider path uses semantic spelling {forbidden!r}")
    for retired in (
            "seed_std_hof_owner", "require_std_hof_seed",
            "seed_std_hof_owners"):
        if retired in builtins:
            errors.append(f"builtin provisional HOF path returned: {retired}")
    install_builtin = _trait_method_function_body(
        sources, "builtins", "install_builtin_method_owner", errors)
    for token in (
        "builtin_impl_provider(provider_site)",
        "provider_ref: some(provider_ref)", "trait_ref: trait_ref",
        "owner_ref: some(owner_ref)", "method_refs: method_refs",
    ):
        if token not in install_builtin:
            errors.append(f"builtin final owner misses {token!r}")

    collect_body = _trait_method_function_body(
        sources, "derive", "collect_user_types", errors)
    if collect_body.count("provider_plan: def.derived_provider_plan.unwrap()") != 2:
        errors.append("derive registry does not copy both nominal provider plans")
    explicit_body = _trait_method_function_body(
        sources, "derive", "explicit_derive_request", errors)
    for token in (
        "ut.provider_plan.explicit_providers.len() != ut.derive_attrs.len()",
        "request.attribute.trait_name != attribute.trait_name",
        "return some(request)",
    ):
        if token not in explicit_body:
            errors.append(f"explicit derive provider selection misses {token!r}")
    derive_register = _trait_method_function_body(
        sources, "derive", "register_derived_impl", errors)
    for token in (
        "provider_ref: some(provider_ref)", "trait_ref: some(trait_ref)",
        "owner_ref: some(owner_ref)", "method_refs: method_refs",
    ):
        if token not in derive_register:
            errors.append(f"derived owner provider closure misses {token!r}")
    if "make_impl_provider_ref(" in derive:
        errors.append("derive remints provider identity")
    if derive.count("implicit_derive_provider(ut)") != 2:
        errors.append("implicit derived owners do not share the nominal provider")
    json_body = _trait_method_function_body(
        sources, "derive", "derive_json_trait", errors)
    for token in (
        "let provider_ref = explicit_derive_request(",
        "env, ut, plan, provider_ref",
        'env, ut, "Json", known, provider_ref',
        "some(di.trait_ref), di.provider_ref",
        "finalize_derived_impl(",
    ):
        if token not in json_body:
            errors.append(
                f"explicit Json descriptor provider chain misses {token!r}")
    if json_body.count("let provider_ref = explicit_derive_request(") != 2:
        errors.append("explicit Json descriptor provider census drifted")

    rebind_body = _trait_method_function_body(
        sources, "decl", "store_rebound_impl_method_scheme", errors)
    for token in (
        "let owner = match find_impl_by_provider(",
        "impl_owner_ref_provider(owner_ref)",
        "owner.method_refs.get(method_name).unwrap()",
    ):
        if token not in rebind_body:
            errors.append(f"impl rebind provider copy misses {token!r}")
    for token in ("ImplProviderRef", "impl_provider_ref_"):
        if token in sources["codegen"]:
            errors.append(f"backend reads 3a1 provider identity {token!r}")
    return errors


def impl_provider_u1c1_mutation_errors(
    sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    mutations = (
        ("module-body owner", "identity", "make_impl_provider_ref",
         "path_owner_ref_is_symbol(owner)", "false"),
        ("source declaration role", "identity", "make_impl_provider_ref",
         "path_role_same(role, path_role_declaration())",
         "path_role_same(role, path_role_synthetic())"),
        ("generated synthetic role", "identity", "make_impl_provider_ref",
         "else if !path_role_same(role, path_role_synthetic())", "else if false"),
        ("provider path equality", "identity", "impl_provider_ref_same",
         "path_ref_same(left.site, right.site)", "true"),
        ("provider kind equality", "identity", "impl_provider_ref_same",
         "impl_provider_kind_same(left.kind, right.kind)", "true"),
        ("source module frame", "resolver", "source_provider_ref",
         'frame.file_key, "frame:${frame.frame_index}"',
         'frame.file_key, "frame:0"'),
        ("delegate raw member", "resolver", "source_delegate_provider_ref",
         '"decl:${decl_index}", "delegate:${source_member_index}"',
         '"decl:${decl_index}", "delegate:0"'),
        ("delegate provider kind", "resolver", "source_delegate_provider_ref",
         "impl_provider_kind_delegate()", "impl_provider_kind_derived()"),
        ("implicit derive site", "resolver", "collect_nominal_derived_provider_fact",
         '"decl:${decl_index}", "derive:implicit"',
         '"decl:${decl_index}", "derive:attr:0"'),
        ("explicit derive site", "resolver", "collect_nominal_derived_provider_fact",
         '"decl:${decl_index}", "derive:attr:${attr_index}"',
         '"decl:${decl_index}", "derive:implicit"'),
        ("explicit attr order", "resolver", "collect_nominal_derived_provider_fact",
         "attr_index: attr_index", "attr_index: 0"),
        ("delegate parent provider", "resolver", "collect_impl_provider_facts",
         "parent_provider_ref: source", "parent_provider_ref: provider_ref"),
        ("source fact exact frame", "resolver", "append_source_impl_provider_fact",
         "existing.frame_index == fact.frame_index", "true"),
        ("delegate fact exact member", "resolver", "append_delegate_provider_fact",
         "existing.source_member_index == fact.source_member_index", "true"),
        ("nominal fact exact decl", "resolver", "append_nominal_derived_provider_fact",
         "existing.decl_index == fact.decl_index", "true"),
        ("resolved source fact dedupe", "resolver", "resolve_namespace_plan",
         "append_source_impl_provider_fact(fact, source_impl_providers)",
         "source_impl_providers.push(fact)"),
        ("resolved delegate fact dedupe", "resolver", "resolve_namespace_plan",
         "append_delegate_provider_fact(fact, delegate_providers)",
         "delegate_providers.push(fact)"),
        ("resolved nominal fact dedupe", "resolver", "resolve_namespace_plan",
         "append_nominal_derived_provider_fact(\n                fact, nominal_derived_providers)",
         "nominal_derived_providers.push(fact)"),
        ("source peek declaration", "ctx", "peek_source_impl_provider_fact",
         "fact.decl_index == decl_index", "true"),
        ("source consume once", "ctx", "commit_source_impl_provider_fact",
         "if matches != 1", "if false"),
        ("delegate peek member", "ctx", "peek_delegate_provider_fact",
         "fact.source_member_index == source_member_index", "true"),
        ("delegate consume once", "ctx", "commit_delegate_provider_fact",
         "if matches != 1", "if false"),
        ("derive attr count", "ctx", "peek_nominal_derived_provider_fact",
         "fact.explicit_providers.len() != attr_count", "false"),
        ("derive attr order", "ctx", "peek_nominal_derived_provider_fact",
         "explicit.attr_index != index", "false"),
        ("derive consume once", "ctx", "commit_nominal_derived_provider_fact",
         "if matches != 1", "if false"),
        ("close source facts", "ctx", "close_struct_identity_ledger",
         "ctx.source_impl_provider_unconsumed.len() != 0", "false"),
        ("close delegate facts", "ctx", "close_struct_identity_ledger",
         "ctx.delegate_provider_unconsumed.len() != 0", "false"),
        ("close derive facts", "ctx", "close_struct_identity_ledger",
         "ctx.nominal_derived_provider_unconsumed.len() != 0", "false"),
        ("method/provider closure", "env", "validate_impl_entry",
         "entry.method_refs.len() != entry.method_schemes.len()", "false"),
        ("final provider", "env", "validate_impl_entry",
         "match (entry.provider_ref, entry.owner_ref)",
         "match (none, entry.owner_ref)"),
        ("exact trait relation", "env", "validate_impl_entry",
         "registered_trait_ref_symbol(def.owner_ref), trait_ref", "trait_ref, trait_ref"),
        ("owner key target", "env", "impl_entry_exact_key_same",
         "match (left.owner_ref, right.owner_ref)",
         "match (none, right.owner_ref)"),
        ("owner key trait", "env", "impl_entry_exact_key_same",
         "impl_owner_ref_same(a, b)", "true"),
        ("owner key provider", "env", "impl_entry_exact_key_same",
         "impl_owner_ref_same(a, b)", "impl_owner_ref_same(a, a)"),
        ("method owner lookup", "env", "install_method_core",
         "find_impl_by_provider(", "find_impl_by_origin("),
        ("method exact trait", "env", "install_method_core",
         "impl_owner_ref_trait(incoming_owner)", "none"),
        ("registry typed key", "env", "add_impl",
         "impl_entry_exact_key_same(existing, entry)",
         "false"),
        ("source provider zero consume", "register", "register_impl",
         "commit_source_impl_provider_fact(ctx, provider_fact)", "{}"),
        ("source owner provider", "register", "register_impl_canonical",
         "provider_ref: some(provider_ref)", "provider_ref: none"),
        ("nominal derive zero consume", "register", "consume_nominal_derived_provider_plan",
         "commit_nominal_derived_provider_fact(ctx, fact)", "{}"),
        ("nominal derive attr order", "register", "consume_nominal_derived_provider_plan",
         "value.attr_index != attr_index", "false"),
        ("delegate typed lookup", "register", "register_phase3_delegate",
         "find_impl_by_provider(", "find_impl_by_origin("),
        ("delegate parent relation", "register", "register_phase3_delegate",
         "impl_provider_ref_same(\n                            fact.parent_provider_ref, parent_provider_ref)",
         "true"),
        ("nonproject provider frame", "register", "register_nonproject_phase3_delegate",
         "enter_struct_identity_child_frame(ctx, item.decl_index)", "{}"),
        ("project provider frame", "register", "register_project_phase3_delegate",
         "exit_struct_identity_frame(ctx)", "{}"),
        ("builtin provider domain", "builtins", "builtin_impl_provider",
         "impl_provider_kind_builtin()", "impl_provider_kind_derived()"),
        ("builtin string path", "builtins", "builtin_impl_provider",
         "[ordinal.to_str()]", '["trait", ordinal.to_str()]'),
        ("builtin ordinal order", "builtins", "builtin_impl_provider_site_from_tag",
         "ordinal != expected", "false"),
        ("builtin ordinal duplicate", "builtins", "builtin_impl_provider_site_from_tag",
         "seen.contains(ordinal)", "false"),
        ("builtin site bypass", "builtins", "install_builtin_method_owner",
         "builtin_impl_provider(provider_site)",
         "builtin_impl_provider(builtin_trait_factory_site())"),
        ("builtin final owner", "builtins", "install_builtin_method_owner",
         "owner_ref: some(owner_ref)", "owner_ref: none"),
        ("derive remint", "derive", "register_derived_impl",
         "provider_ref: some(provider_ref)",
         "provider_ref: some(make_impl_provider_ref(provider_ref))"),
        ("implicit derive copy", "derive", "derive_trait",
         "implicit_derive_provider(ut)",
         "explicit_derive_request(ut, trait_name).unwrap().provider_ref"),
        ("rebind provider copy", "decl", "store_rebound_impl_method_scheme",
         "owner.method_refs.get(method_name).unwrap()",
         "wrong_method_ref"),
    )
    killed = 0
    for label, source_name, function_name, anchor, replacement in mutations:
        mutated_source, mutation_error = _f0_mutate_function_once(
            sources[source_name], function_name, anchor, replacement)
        if mutation_error:
            errors.append(f"impl provider mutation {label}: {mutation_error}")
            continue
        assert mutated_source is not None
        mutated = dict(sources)
        mutated[source_name] = mutated_source
        findings = impl_provider_u1c1_contract_errors(mutated)
        if not findings:
            errors.append(f"impl provider mutation escaped: {label}")
        else:
            killed += 1
    if killed != F2_IMPL_PROVIDER_MUTATION_COUNT:
        errors.append(
            f"impl provider killed {killed} mutations, expected "
            f"{F2_IMPL_PROVIDER_MUTATION_COUNT}")
    return errors


def impl_provider_u1c1_source_errors() -> List[str]:
    sources: dict[str, str] = {}
    try:
        for name, path in F2_IMPL_PROVIDER_PATHS.items():
            sources[name] = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read impl provider compiler sources: {exc}"]
    errors = impl_provider_u1c1_contract_errors(sources)
    if errors:
        return errors
    errors.extend(impl_provider_u1c1_mutation_errors(sources))
    return errors


F2_IMPL_PROVIDER_CARRIER_PATHS = {
    "hir": REPO / "compiler" / "hir.ring",
    "checker": REPO / "compiler" / "checker.ring",
    "exports": REPO / "compiler" / "exports.ring",
    "decl": REPO / "compiler" / "infer_decl.ring",
    "core": REPO / "compiler" / "core_from_hir.ring",
    "core_expr": REPO / "compiler" / "core_expr.ring",
    "codegen": REPO / "compiler" / "codegen_c.ring",
}
F2_IMPL_PROVIDER_CARRIER_MUTATION_COUNT = 17
F2_IMPL_PROVIDER_CARRIER_SCOPE_COUNT = 1


def impl_provider_u1c2_contract_errors(
    sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    hir = sources["hir"]
    fact_fields, fact_error = _f0_struct_fields(hir, "ModuleImplFact")
    if fact_error:
        errors.append(fact_error)
    elif fact_fields is not None and [
            name for _, name in fact_fields] != [
                "target", "provider_ref", "trait_ref", "owner_ref",
                "method_names", "public_inherent_method_names",
                "is_top_level"]:
        errors.append("impl provider carrier: ModuleImplFact inventory drifted")
    if "is_trait_impl" in hir:
        errors.append("impl provider carrier: second trait truth returned")

    hir_validate = _trait_method_function_body(
        sources, "hir", "validate_hir_decls", errors)
    for token in (
        "impl_provider_ref_kind(provider_ref)",
        "impl_provider_kind_tag(",
        "trait_name.is_some() != trait_ref.is_some()",
        "impl trait name/ref presence drifted",
        "impl_owner_ref_provider(owner_ref), provider_ref",
        "impl_owner_ref_trait(owner_ref), trait_ref",
    ):
        if token not in hir_validate:
            errors.append(f"impl provider HIR validator misses {token!r}")

    source_body = _trait_method_function_body(
        sources, "decl", "check_impl_decl_canonical", errors)
    for token in (
        "let provider_ref = match impl_owner.provider_ref",
        "provider_ref: provider_ref, trait_ref: impl_owner.trait_ref",
    ):
        if token not in source_body:
            errors.append(f"source impl carrier misses {token!r}")
    delegate_body = _trait_method_function_body(
        sources, "decl", "expand_delegate_impls", errors)
    for token in (
        "let selected_delegate_owner = match delegate_impl",
        "selected_delegate_owner.provider_ref",
        "provider_ref: selected_delegate_provider",
        "trait_ref: selected_delegate_owner.trait_ref",
    ):
        if token not in delegate_body:
            errors.append(f"delegate impl carrier misses {token!r}")

    checker = sources["checker"]
    carrier_body = _trait_method_function_body(
        sources, "checker", "validate_impl_carriers", errors)
    for token in (
        "find_impl_by_provider(",
        "env.trait_reg, target_type, trait_ref, provider_ref",
        "optional_symbol_ref_same(owner.trait_ref, trait_ref)",
        "owner.method_schemes.contains_key(name)",
        "validate_impl_carriers(env, inner)",
    ):
        if token not in carrier_body:
            errors.append(f"checker impl carrier closure misses {token!r}")
    collect_body = _trait_method_function_body(
        sources, "checker", "collect_module_impl_facts", errors)
    for token in (
        "find_impl_by_provider(", "provider_ref: provider_ref",
        "trait_ref: trait_ref", "owner_ref: owner_ref",
    ):
        if token not in collect_body:
            errors.append(f"ModuleImplFact collector misses {token!r}")
    for forbidden in (
            "exact_module_impl_owner", "trait_impls.get(",
            "method_origins.get(", "MethodOrigin"):
        if forbidden in collect_body or forbidden in checker:
            errors.append(f"ModuleImplFact collector retained {forbidden!r}")
    for function_name in ("check", "check_module"):
        body = _trait_method_function_body(
            sources, "checker", function_name, errors)
        validate_at = body.find("validate_impl_carriers(")
        collect_at = body.find("collect_module_impl_facts(")
        if min(validate_at, collect_at) < 0 or validate_at > collect_at:
            errors.append(f"{function_name} publishes facts before validation")

    exports = sources["exports"]
    append_body = _trait_method_function_body(
        sources, "exports", "append_exact_impl_owner", errors)
    if ("impl_entry_exact_key_same(existing, owner)" not in append_body or
            "!impl_entry_final_same(existing, owner)" not in append_body):
        errors.append("export owner union is not typed/structural")
    facts_body = _trait_method_function_body(
        sources, "exports", "export_impl_facts", errors)
    for token in (
        "find_impl_by_provider(", "fact.trait_ref, fact.provider_ref",
        "impl_owner_ref_same(",
        "impl_entry_exact_key_same(seen, owner)",
        "method_ref_matches_owner(",
    ):
        if token not in facts_body:
            errors.append(f"export impl fact closure misses {token!r}")
    method_insert = _trait_method_function_body(
        sources, "exports", "insert_exact_method_ref", errors)
    for token in (
        "target_index.get(method_name)",
        "impl_method_ref_same(existing, method_ref)",
        "target_index.insert(method_name, method_ref)",
    ):
        if token not in method_insert:
            errors.append(f"exact export method index misses {token!r}")
    inject_body = _trait_method_function_body(
        sources, "checker", "inject_module_exports", errors)
    for token in (
        "let owner_ref = impl_method_ref_owner(method_ref)",
        "find_impl_by_provider(", "impl_owner_ref_trait(owner_ref)",
        "impl_owner_ref_provider(owner_ref)",
        "some(expected) => if !impl_method_ref_same(",
        "expected, method_ref",
    ):
        if token not in inject_body:
            errors.append(f"hydration typed owner closure misses {token!r}")

    core_impl_fields, core_impl_error = _f0_struct_fields(
        sources["core_expr"], "CoreImplMetadata")
    if core_impl_error:
        errors.append(core_impl_error)
    elif core_impl_fields is not None and [
            name for _, name in core_impl_fields] != [
                "owner", "methods", "assoc_bindings"]:
        errors.append("Core impl metadata gained a name/span/fallback carrier")
    core_impl = _trait_method_function_body(
        sources, "core_expr", "make_core_impl_metadata", errors)
    for token in (
            "impl_owner_ref_same(impl_method_ref_owner(method), owner)",
            "impl_method_ref_callable_slot_index(method)",
            "CoreImplMetadata {"):
        if token not in core_impl:
            errors.append(f"Core impl registry validation misses {token!r}")
    core_assembly = _trait_method_function_body(
        sources, "core", "assemble_decls", errors)
    for token in (
            "HDecl::Impl {",
            "owner_ref, delegate_plan, default_specializations,",
            "assembly.impls.push(make_core_impl_metadata(",
            "owner_ref, method_refs, bindings"):
        if token not in core_assembly:
            errors.append(f"HIR/Core impl carrier misses {token!r}")

    for source_name in ("codegen",):
        masked = mask_ring_strings_and_comments(sources[source_name])
        if "ImplProviderRef" in masked or "provider_ref" in masked or (
                "trait_ref" in masked):
            errors.append(f"{source_name} semantically reads impl provider carrier")
    return errors


def impl_provider_u1c2_mutation_errors(
    sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    mutations = (
        ("HIR provider validation", "hir", "validate_hir_decls",
         "impl_provider_ref_kind(provider_ref)",
         "impl_provider_ref_kind(wrong_provider_ref)"),
        ("HIR trait presence", "hir", "validate_hir_decls",
         "trait_name.is_some() != trait_ref.is_some()", "false"),
        ("HIR owner/provider relation", "hir", "validate_hir_decls",
         "impl_owner_ref_provider(owner_ref), provider_ref",
         "provider_ref, provider_ref"),
        ("HIR owner/trait relation", "hir", "validate_hir_decls",
         "impl_owner_ref_trait(owner_ref), trait_ref",
         "trait_ref, trait_ref"),
        ("source provider", "decl", "check_impl_decl_canonical",
         "provider_ref: provider_ref", "provider_ref: wrong_provider_ref"),
        ("source trait", "decl", "check_impl_decl_canonical",
         "trait_ref: impl_owner.trait_ref", "trait_ref: none"),
        ("delegate provider", "decl", "expand_delegate_impls",
         "provider_ref: selected_delegate_provider",
         "provider_ref: wrong_provider_ref"),
        ("delegate trait", "decl", "expand_delegate_impls",
         "trait_ref: selected_delegate_owner.trait_ref", "trait_ref: none"),
        ("checker provider lookup", "checker", "validate_impl_carriers",
         "find_impl_by_provider(", "find_impl_by_origin("),
        ("collector provider", "checker", "collect_module_impl_facts",
         "provider_ref: provider_ref", "provider_ref: wrong_provider_ref"),
        ("collector trait", "checker", "collect_module_impl_facts",
         "trait_ref: trait_ref", "trait_ref: none"),
        ("export typed union", "exports", "append_exact_impl_owner",
         "impl_entry_exact_key_same(existing, owner)", "true"),
        ("export fact provider", "exports", "export_impl_facts",
         "fact.trait_ref, fact.provider_ref",
         "fact.trait_ref, wrong_provider_ref"),
        ("exact export method", "exports", "insert_exact_method_ref",
         "impl_method_ref_same(existing, method_ref)",
         "true"),
        ("hydration provider", "checker", "inject_module_exports",
         "impl_owner_ref_provider(owner_ref)",
         "wrong_provider_ref"),
        ("Core impl owner", "core", "assemble_decls",
         "owner_ref, method_refs, bindings",
         "missing, method_refs, bindings"),
        ("Core method owner validation", "core_expr",
         "make_core_impl_metadata",
         "impl_owner_ref_same(impl_method_ref_owner(method), owner)",
         "true"),
    )
    killed = 0
    for label, source_name, function_name, anchor, replacement in mutations:
        mutated_source, mutation_error = _f0_mutate_function_once(
            sources[source_name], function_name, anchor, replacement)
        if mutation_error:
            errors.append(f"impl provider carrier mutation {label}: {mutation_error}")
            continue
        assert mutated_source is not None
        mutated = dict(sources)
        mutated[source_name] = mutated_source
        if not impl_provider_u1c2_contract_errors(mutated):
            errors.append(f"impl provider carrier mutation escaped: {label}")
        else:
            killed += 1

    if killed != F2_IMPL_PROVIDER_CARRIER_MUTATION_COUNT:
        errors.append(
            f"impl provider carrier killed {killed} mutations, expected "
            f"{F2_IMPL_PROVIDER_CARRIER_MUTATION_COUNT}")
    return errors


def impl_provider_u1c2_scope_errors(
    sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    for source_name in ("codegen",):
        mutated = dict(sources)
        mutated[source_name] = sources[source_name] + (
            "\nfn forbidden_impl_provider_read(provider_ref: ImplProviderRef) "
            "{ let _ = provider_ref }\n")
        if not impl_provider_u1c2_contract_errors(mutated):
            errors.append(f"impl provider carrier scope escaped: {source_name}")
    return errors


def impl_provider_u1c2_source_errors() -> List[str]:
    sources: dict[str, str] = {}
    try:
        for name, path in F2_IMPL_PROVIDER_CARRIER_PATHS.items():
            sources[name] = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read impl provider carrier sources: {exc}"]
    errors = impl_provider_u1c2_contract_errors(sources)
    if errors:
        return errors
    errors.extend(impl_provider_u1c2_mutation_errors(sources))
    errors.extend(impl_provider_u1c2_scope_errors(sources))
    return errors


F2_DERIVED_IMPL_CARRIER_PATHS = {
    "hir": REPO / "compiler" / "hir.ring",
    "derive": REPO / "compiler" / "derive.ring",
    "builtins": REPO / "compiler" / "builtins.ring",
    "checker": REPO / "compiler" / "checker.ring",
    "project": REPO / "compiler" / "compiler_mod.ring",
    "dict": REPO / "compiler" / "dict_lower.ring",
    "core": REPO / "compiler" / "core_from_hir.ring",
    "codegen": REPO / "compiler" / "codegen_c.ring",
}
F2_DERIVED_IMPL_CARRIER_MUTATION_COUNT = 17


def derived_impl_carrier_u1c4_contract_errors(
    sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    hir = sources["hir"]
    derive = sources["derive"]
    builtins = sources["builtins"]
    checker = sources["checker"]
    project = sources["project"]
    core = sources["core"]
    codegen = sources["codegen"]

    fields, field_error = _f0_struct_fields(hir, "DerivedImpl")
    if field_error:
        errors.append(field_error)
    elif fields is not None and [name for _, name in fields] != [
            "semantic_kind", "owner_ref", "provider_ref", "trait_ref",
            "target_owner", "target_type", "methods", "hash_mix",
            "text_plan", "type_name", "trait_name", "type_params",
            "bounds", "type_kind", "struct_fields", "enum_variants"]:
        errors.append("derived impl carrier inventory drifted")
    if ("pub struct DerivedImpl {\n"
            "    pub semantic_kind: DerivedSemanticKind,\n"
            "    pub owner_ref: ImplOwnerRef,\n"
            "    pub provider_ref: ImplProviderRef," not in hir or
            "pub type_params: List<HTypeParam>" not in hir):
        errors.append("derived impl carrier identity types drifted")

    register = _trait_method_function_body(
        sources, "derive", "register_derived_impl", errors)
    for token in (
        "let trait_name = di.trait_name",
        "let provider_ref = di.provider_ref",
        "registered_derive_trait_ref(env, trait_name)",
        "!symbol_ref_same(trait_ref, di.trait_ref)",
        "provider_ref: some(provider_ref)",
        "trait_ref: some(trait_ref)",
    ):
        if token not in register:
            errors.append(f"derived owner registration misses {token!r}")

    finalize = _trait_method_function_body(
        sources, "derive", "finalize_derived_impl", errors)
    for token in (
        "let owner_provider = match owner.provider_ref",
        "let owner_trait = match owner.trait_ref",
        "!impl_provider_ref_same(owner_provider, di.provider_ref)",
        "!symbol_ref_same(owner_trait, di.trait_ref)",
        "derived_runtime_bounds_from_owner(env, owner)",
        "type_params: derived_h_type_params(env, owner)",
        "provider_ref: owner_provider",
        "trait_ref: owner_trait",
    ):
        if token not in finalize:
            errors.append(f"derived descriptor finalizer misses {token!r}")

    json_body = _trait_method_function_body(
        sources, "derive", "derive_json_trait", errors)
    for token in (
        "let provider_ref = explicit_derive_request(",
        "find_impl_by_provider(",
        "some(di.trait_ref), di.provider_ref",
        "finalize_derived_impl(",
    ):
        if token not in json_body:
            errors.append(f"Json derived descriptor misses {token!r}")
    if "find_impl(\n                        env.trait_reg, ut.name, \"Json\")" in json_body:
        errors.append("Json derived descriptor falls back to trait name lookup")

    owner_match = _trait_method_function_body(
        sources, "derive", "derived_impl_matches_owner", errors)
    for token in (
        "impl_provider_ref_same(", "symbol_ref_same(",
        "owner.target_type_name != di.type_name",
        "derived_h_type_params(env, owner), di.type_params",
        "derived_runtime_bounds_from_owner(env, owner), di.bounds",
    ):
        if token not in owner_match:
            errors.append(f"derived descriptor owner relation misses {token!r}")
    validate = _trait_method_function_body(
        sources, "derive", "validate_derived_impls", errors)
    for token in (
        "derived_impl_key_same(existing, di)",
        "find_impl_by_provider(",
        "some(di.trait_ref), di.provider_ref",
        "derived_impl_matches_owner(env, di, owner)",
        "impl_provider_kind_builtin()",
        "impl_provider_kind_derived()",
        "if matches != 1",
    ):
        if token not in validate:
            errors.append(f"derived descriptor validator misses {token!r}")

    census = (
        'const BUILTIN_OPTION_DERIVED_TRAITS: List<Str> = '
        '["Eq", "Debug", "Clone"]')
    if census not in builtins:
        errors.append("builtin Option derived owner census drifted")
    builtin_owners = _trait_method_function_body(
        sources, "builtins", "builtin_option_derived_owners", errors)
    for token in (
        "require_builtin_option_derived_owner(env, trait_name)",
        "find_impl_by_provider(",
        "some(ord_ref), provider_ref",
        ").is_some()",
        "builtin Option derived owner census gained Ord",
    ):
        if token not in builtin_owners:
            errors.append(f"builtin Option owner census misses {token!r}")
    require_builtin = _trait_method_function_body(
        sources, "builtins", "require_builtin_option_derived_owner", errors)
    for token in (
        "find_impl_by_provider(",
        "some(trait_ref), provider_ref",
        "builtin Option derived owner is missing",
    ):
        if token not in require_builtin:
            errors.append(f"builtin Option exact owner lookup misses {token!r}")
    option_descriptor = _trait_method_function_body(
        sources, "derive", "builtin_option_derived_impl", errors)
    for token in (
        "derived_runtime_bounds_from_owner(env, owner)",
        "if bounds.len() != 1",
        'bound.type_param != "T" || bound.trait_name != trait_name',
        '"Eq" => some([', '"Debug" => some([', '"Clone" => some([',
        "provider_ref: provider_ref", "trait_ref: trait_ref",
    ):
        if token not in option_descriptor:
            errors.append(f"builtin Option descriptor misses {token!r}")
    option_list = _trait_method_function_body(
        sources, "derive", "builtin_option_derived_impls", errors)
    for token in (
        "result.len() != 3",
        'result.get(0).unwrap().trait_name != "Eq"',
        'result.get(1).unwrap().trait_name != "Debug"',
        'result.get(2).unwrap().trait_name != "Clone"',
    ):
        if token not in option_list:
            errors.append(f"builtin Option descriptor order misses {token!r}")
    derive_pass = _trait_method_function_body(
        sources, "derive", "run_derive_pass", errors)
    for token in (
            "if ctx.core_module_order == 0",
            "for builtin in builtin_option_derived_impls(ctx.env)",
            "for derived in derived_impls { exact.push(derived) }",
            "close_derived_text_plans(ctx, exact)"):
        if token not in derive_pass:
            errors.append(f"derive pass physical carrier misses {token!r}")

    single = _trait_method_function_body(sources, "checker", "check", errors)
    single_validate = single.find("validate_derived_impls(")
    single_lower = single.find("lower_dicts(lower_andor(assembled))")
    if min(single_validate, single_lower) < 0 or single_validate > single_lower:
        errors.append("single checker derived validation order drifted")
    module_check = _trait_method_function_body(
        sources, "checker", "check_module", errors)
    module_validate = module_check.find("validate_derived_impls(")
    module_lower = module_check.find("lower_dicts(lower_andor(assembled))")
    if min(module_validate, module_lower) < 0 or module_validate > module_lower:
        errors.append("module checker derived validation order drifted")
    if "assemble_project_builtin_derived_impls" in project or (
            "prepend_builtin_option_derived_impls" in project):
        errors.append("project retained a second builtin derived assembly authority")

    dict_body = _trait_method_function_body(
        sources, "dict", "dl_derived_impl", errors)
    for token in (
            "provider_ref: di.provider_ref", "trait_ref: di.trait_ref",
            "type_params: di.type_params"):
        if token not in dict_body:
            errors.append(f"dict lowering loses derived carrier {token!r}")

    append_core = _trait_method_function_body(
        sources, "core", "append_derived_impl", errors)
    for token in (
            "derived_semantic_kind_tag(",
            "make_core_impl_metadata("):
        if token not in append_core:
            errors.append(f"Core derived consumer misses {token!r}")

    codegen_masked = mask_ring_strings_and_comments(codegen)
    for forbidden in (
        "emit_c_builtin_derived_impls", "c_option_some_variant",
        "c_option_none_variant", "emit_c_derived_impls",
        "emit_c_derived_impl_bodies",
    ):
        if forbidden in codegen_masked:
            errors.append(f"C backend retains derived authority {forbidden!r}")
    if "DerivedImpl {" in codegen_masked:
        errors.append("C backend constructs a derived descriptor")
    if codegen.count(
            "C ABI boundary: semantic DerivedImpl carrier was not retired") != 1:
        errors.append("C backend derived retirement boundary drifted")
    if codegen.count(
            "C ABI boundary: project DerivedImpl carrier was not retired") != 1:
        errors.append("project C backend derived retirement boundary drifted")
    return errors


def derived_impl_carrier_u1c4_mutation_errors(
    sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    mutations = (
        ("register trait relation", "derive", "register_derived_impl",
         "!symbol_ref_same(trait_ref, di.trait_ref)", "false"),
        ("final provider copy", "derive", "finalize_derived_impl",
         "provider_ref: owner_provider", "provider_ref: di.provider_ref"),
        ("final exact type params", "derive", "finalize_derived_impl",
         "type_params: derived_h_type_params(env, owner)",
         "type_params: []"),
        ("validator typed owner", "derive", "validate_derived_impls",
         "find_impl_by_provider(", "find_impl("),
        ("validator owner relation", "derive", "validate_derived_impls",
         "derived_impl_matches_owner(env, di, owner)", "true"),
        ("validator type parameters", "derive", "derived_impl_matches_owner",
         "derived_h_type_params(env, owner), di.type_params",
         "di.type_params, di.type_params"),
        ("Option exact predicate", "derive", "builtin_option_derived_impl",
         "if bounds.len() != 1", "if false"),
        ("order-zero physical carrier", "derive", "run_derive_pass",
         "if ctx.core_module_order == 0", "if true"),
        ("dict exact type params", "dict", "dl_derived_impl",
         "type_params: di.type_params", "type_params: []"),
        ("Core semantic tag", "core", "append_derived_impl",
         "derived_semantic_kind_tag(", "derived_semantic_kind_tag_broken("),
        ("single validation", "checker", "check",
         "validate_derived_impls(ctx.env, derived_impls)", "{}"),
        ("module validation", "checker", "check_module",
         "validate_derived_impls(ctx.env, hprogram.derived_impls)", "{}"),
    )
    killed = 0
    for label, source_name, function_name, anchor, replacement in mutations:
        mutated_source, mutation_error = _f0_mutate_function_once(
            sources[source_name], function_name, anchor, replacement)
        if mutation_error:
            errors.append(f"derived carrier mutation {label}: {mutation_error}")
            continue
        assert mutated_source is not None
        mutated = dict(sources)
        mutated[source_name] = mutated_source
        if not derived_impl_carrier_u1c4_contract_errors(mutated):
            errors.append(f"derived carrier mutation escaped: {label}")
        else:
            killed += 1

    manual_mutations = (
        ("owner schema optional", "hir",
         "pub struct DerivedImpl {\n"
         "    pub semantic_kind: DerivedSemanticKind,\n"
         "    pub owner_ref: ImplOwnerRef,",
         "pub struct DerivedImpl {\n"
         "    pub semantic_kind: DerivedSemanticKind,\n"
         "    pub owner_ref: ImplOwnerRef?,"),
        ("type parameters lose exact ids", "hir",
         "    pub type_params: List<HTypeParam>,",
         "    pub type_params: List<Str>,"),
        ("Option Ord census", "builtins",
         '["Eq", "Debug", "Clone"]', '["Eq", "Debug", "Ord", "Clone"]'),
        ("backend accepts pending descriptor", "codegen",
         "C ABI boundary: semantic DerivedImpl carrier was not retired",
         "C ABI boundary: pending descriptor accepted"),
        ("backend descriptor constructor", "codegen",
         "pub fn generate_c(",
         "fn forged() { let _ = DerivedImpl { } }\npub fn generate_c("),
    )
    for label, source_name, anchor, replacement in manual_mutations:
        source = sources[source_name]
        if source.count(anchor) != 1:
            errors.append(
                f"derived carrier mutation {label}: anchor count "
                f"was {source.count(anchor)}")
            continue
        mutated = dict(sources)
        mutated[source_name] = source.replace(anchor, replacement, 1)
        if not derived_impl_carrier_u1c4_contract_errors(mutated):
            errors.append(f"derived carrier mutation escaped: {label}")
        else:
            killed += 1
    if killed != F2_DERIVED_IMPL_CARRIER_MUTATION_COUNT:
        errors.append(
            f"derived carrier killed {killed} mutations, expected "
            f"{F2_DERIVED_IMPL_CARRIER_MUTATION_COUNT}")
    return errors


def derived_impl_carrier_u1c4_fixture_errors(ring_exe: str) -> List[str]:
    errors: List[str] = []
    compiler = Path(ring_exe).resolve(strict=True)
    compiler_before = _sha256_file(compiler)
    environment = dict(_controlled_environment(str(compiler)))
    negative = CASES_DIR / "error_option_ord_unavailable.ring"
    if negative not in discover_negative_cases(CASES_DIR):
        errors.append("Option Ord negative fixture is not runner-discovered")
    else:
        try:
            completed = subprocess.run(
                [str(compiler), "check", str(negative)],
                cwd=REPO, env=environment, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, encoding="utf-8", errors="strict",
                check=False, timeout=120)
        except subprocess.TimeoutExpired:
            errors.append("Option Ord negative fixture timed out")
        else:
            if completed.returncode == 0:
                errors.append("Option Ord negative unexpectedly passed")
            else:
                contract = negative.with_suffix(".error").read_text(
                    encoding="utf-8")
                combined = (completed.stdout or "") + (completed.stderr or "")
                contract_error = error_contract_failure(contract, combined)
                if contract_error is not None:
                    errors.append(
                        "Option Ord negative contract failed: "
                        f"{contract_error}; output={combined[:300]!r}")
    if _sha256_file(compiler) != compiler_before:
        errors.append("pinned Ring compiler changed across derived fixtures")
    return errors


def derived_impl_carrier_u1c4_source_errors() -> List[str]:
    sources: dict[str, str] = {}
    try:
        for name, path in F2_DERIVED_IMPL_CARRIER_PATHS.items():
            sources[name] = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read derived impl carrier sources: {exc}"]
    errors = derived_impl_carrier_u1c4_contract_errors(sources)
    if errors:
        return errors
    errors.extend(derived_impl_carrier_u1c4_mutation_errors(sources))
    return errors


F2_DELEGATE_PROVIDER_PLAN_PATHS = {
    "env": REPO / "compiler" / "env.ring",
    "register": REPO / "compiler" / "infer_register.ring",
    "decl": REPO / "compiler" / "infer_decl.ring",
    "builtins": REPO / "compiler" / "builtins.ring",
    "derive": REPO / "compiler" / "derive.ring",
    "checker": REPO / "compiler" / "checker.ring",
}
F2_DELEGATE_PROVIDER_PLAN_MUTATION_COUNT = 33


def delegate_provider_plan_u1c3_contract_errors(
    sources: Mapping[str, str],
) -> List[str]:
    errors: List[str] = []
    env = sources["env"]
    register = sources["register"]
    decl = sources["decl"]

    child_fields, child_error = _f0_struct_fields(
        env, "DelegateChildProviderPlan")
    if child_error:
        errors.append(child_error)
    elif child_fields is not None and [
            name for _, name in child_fields] != [
                "source_member_index", "provider_ref",
                "produced_owner_count", "had_semantic_error"]:
        errors.append("delegate child provider plan inventory drifted")
    elif child_fields is not None and any(
            is_public for is_public, _ in child_fields):
        errors.append("delegate child provider plan exposes forgeable fields")
    state_fields, state_error = _f0_struct_fields(env, "DelegatePlanState")
    if state_error:
        errors.append(state_error)
    elif state_fields is not None:
        if [name for _, name in state_fields] != ["value"]:
            errors.append("delegate plan state inventory drifted")
        if any(is_public for is_public, _ in state_fields):
            errors.append("delegate plan state exposes forgeable fields")
    for token in (
            "DelegateNotApplicable", "DelegatePending",
            "DelegateFinal(List<DelegateChildProviderPlan>)"):
        if token not in env:
            errors.append(f"delegate plan state misses {token!r}")
    child_constructor = _trait_method_function_body(
        sources, "env", "make_delegate_child_provider_plan", errors)
    for token in (
        "source_member_index < 0", "produced_owner_count < 0",
        "produced_owner_count == 0 && !had_semantic_error",
        "impl_provider_kind_delegate()",
        "produced_owner_count: produced_owner_count",
        "had_semantic_error: had_semantic_error",
    ):
        if token not in child_constructor:
            errors.append(f"delegate child constructor misses {token!r}")
    final_constructor = _trait_method_function_body(
        sources, "env", "delegate_plan_final", errors)
    final_accessor = _trait_method_function_body(
        sources, "env", "delegate_plan_children", errors)
    if "copy_delegate_child_provider_plans(children)" not in final_constructor:
        errors.append("delegate Final constructor aliases caller list")
    if "copy_delegate_child_provider_plans(children)" not in final_accessor:
        errors.append("delegate Final accessor exposes mutable list")

    state_same = _trait_method_function_body(
        sources, "env", "delegate_plan_state_same", errors)
    for token in (
        "DelegateNotApplicable", "DelegatePending", "DelegateFinal(a)",
        "(DelegatePlanStateValue::DelegatePending,\n"
        "         DelegatePlanStateValue::DelegatePending) => true",
        "delegate_child_provider_plan_same(", "_ => false",
    ):
        if token not in state_same:
            errors.append(f"delegate plan equality misses {token!r}")
    child_same = _trait_method_function_body(
        sources, "env", "delegate_child_provider_plan_same", errors)
    for token in (
        "left.source_member_index == right.source_member_index",
        "impl_provider_ref_same(left.provider_ref, right.provider_ref)",
        "left.produced_owner_count == right.produced_owner_count",
        "left.had_semantic_error == right.had_semantic_error",
    ):
        if token not in child_same:
            errors.append(f"delegate child equality misses {token!r}")
    final_same = _trait_method_function_body(
        sources, "env", "impl_entry_final_same", errors)
    if "delegate_plan_state_same(left.delegate_plan, right.delegate_plan)" not in final_same:
        errors.append("full ImplEntry equality loses delegate plan state")

    validate = _trait_method_function_body(
        sources, "env", "validate_impl_entry", errors)
    for token in (
        "match (entry.provider_ref, entry.delegate_plan.value)",
        "DelegatePlanStateValue::DelegatePending",
        "impl_provider_kind_source()",
        "pending delegate plan parent is not Source",
        "DelegatePlanStateValue::DelegateFinal(children)",
        "child.produced_owner_count < 0",
        "child.produced_owner_count == 0 &&",
        "!child.had_semantic_error",
        "child.source_member_index <= previous_delegate_index",
        "impl_provider_kind_delegate()",
        "impl_provider_ref_same(",
        "seen_provider, child.provider_ref",
        "duplicate delegate child provider",
        "Source provider has no final delegate plan",
        "provider/delegate plan state mismatch",
    ):
        if token not in validate:
            errors.append(f"delegate plan validator misses {token!r}")
    finalize = _trait_method_function_body(
        sources, "env", "finalize_delegate_provider_plan", errors)
    for token in (
        "provider, parent_provider_ref",
        "entry.trait_ref, trait_ref",
        "!delegate_plan_is_pending(entry.delegate_plan)",
        "updated.delegate_plan = delegate_plan_final(children)",
        "validate_impl_entry(reg, updated)", "if matches != 1",
    ):
        if token not in finalize:
            errors.append(f"delegate plan finalizer misses {token!r}")
    close = _trait_method_function_body(
        sources, "env", "assert_no_pending_delegate_plans", errors)
    if ("delegate_plan_is_pending(owner.delegate_plan)" not in close or
            "pending delegate plan reached close" not in close):
        errors.append("delegate plan close does not reject Pending")
    query = _trait_method_function_body(
        sources, "env", "find_impls_by_provider", errors)
    for token in (
        "reg.trait_impls.get(type_name)",
        "candidate, provider_ref",
        "found.push(entry)",
    ):
        if token not in query:
            errors.append(f"delegate actual-owner query misses {token!r}")

    source_register = _trait_method_function_body(
        sources, "register", "register_impl", errors)
    for token in (
        "let mut has_delegate = false",
        "some(Decl::Delegate { .. }) => { has_delegate = true }",
        "delegate_plan_pending()", "delegate_plan_final([])",
    ):
        if token not in source_register:
            errors.append(f"source delegate plan freeze misses {token!r}")
    for forbidden in (
            "peek_delegate_provider_fact", "commit_delegate_provider_fact"):
        if forbidden in source_register:
            errors.append(f"source phase consumed delegate fact early: {forbidden}")
    phase3 = _trait_method_function_body(
        sources, "register", "register_phase3_delegate", errors)
    for token in (
        "peek_delegate_provider_fact(",
        "commit_delegate_provider_fact(ctx, fact)",
        "fact.parent_provider_ref, parent_provider_ref",
        "find_impl_by_provider(",
        "let outcome = some(register_delegate(",
        "let had_semantic_error = outcome.unwrap_or(true)",
        "let produced_owner_count = find_impls_by_provider(",
        "make_delegate_child_provider_plan(",
        "produced_owner_count,",
        "had_semantic_error",
        "finalize_delegate_provider_plan(",
        "ctx.env.trait_reg, canonical_target,",
        "canonical_trait_ref, parent_provider_ref, child_plans",
        "catch { _ => none }",
    ):
        if token not in phase3:
            errors.append(f"phase3 delegate finalization misses {token!r}")
    finalize_at = phase3.find("finalize_delegate_provider_plan(")
    register_at = phase3.find("some(register_delegate(")
    count_at = phase3.find("find_impls_by_provider(")
    if min(finalize_at, register_at, count_at) < 0 or not (
            register_at < count_at < finalize_at):
        errors.append("phase3 delegate outcome/finalization order drifted")
    register_delegate = _trait_method_function_body(
        sources, "register", "register_delegate", errors)
    register_traits = _trait_method_function_body(
        sources, "register", "register_delegate_traits", errors)
    if register_delegate.count("had_semantic_error = true") < 3:
        errors.append("register_delegate does not return local error outcome")
    if register_traits.count("had_semantic_error = true") < 5:
        errors.append("register_delegate_traits loses report-only errors")
    if ("had_semantic_error = true\n"
            "                        let _ = type_error(ctx.sink, E0509," not in
            register_traits):
        errors.append("manual delegate conflict loses local error outcome")
    if register.count("assert_no_pending_delegate_plans(ctx.env.trait_reg)") != 3:
        errors.append("registration close pending-plan census drifted")

    for source_name in ("builtins", "derive"):
        if "delegate_plan: delegate_plan_not_applicable()" not in sources[source_name]:
            errors.append(f"{source_name} owner can publish delegate plan")
    if "delegate_plan: delegate_plan_not_applicable()" not in register_traits:
        errors.append("generated delegate owner is not NotApplicable")

    expand = _trait_method_function_body(
        sources, "decl", "expand_delegate_impls", errors)
    for token in (
        "match outer_impl",
        "find_impl_by_provider(",
        "outer_trait_ref, outer_provider_ref",
        "find_delegate_child_provider_plan(",
        "find_impls_by_provider(",
        "delegate_child_provider_ref(child_plan)",
        "delegate_child_provider_produced_owner_count(child_plan)",
        "delegate_child_provider_had_semantic_error(child_plan)",
        "produced_owners.len() != produced_owner_count",
        "child provider owner count drifted",
        "if produced_owner_count == 0",
        "if had_semantic_error { return result }",
        "clean child provider produced no owners",
        "for produced_owner in produced_owners",
        "produced_owner.trait_ref", "child trait identity changed",
        "field trait identity changed",
    ):
        if token not in expand:
            errors.append(f"delegate HIR actual-owner query misses {token!r}")
    for forbidden in (
            "trait_names", "let delegate_impl = find_impl(",
            "impl_decl_origin(", "impl_provider_kind_delegate()",
            "ctx.sink.has_errors()"):
        if forbidden in expand:
            errors.append(f"delegate HIR retained fallback {forbidden!r}")
    for function_name in (
            "check_mod_decl_body", "check_one_decl",
            "check_one_decl_with_rebind"):
        body = _trait_method_function_body(
            sources, "decl", function_name, errors)
        for token in (
            "for source_member_index in 0..methods.len()",
            "ctx, hd, source_member_index"):
            if token not in body:
                errors.append(f"{function_name} loses raw delegate index")

    checker_validate = _trait_method_function_body(
        sources, "checker", "validate_impl_carriers", errors)
    if "allow_incomplete" in checker_validate or (
            "none => panic(\"impl HIR: typed owner is missing\")" not in checker_validate):
        errors.append("checker allows typed HDecl owner miss under unrelated errors")
    checker_collect = _trait_method_function_body(
        sources, "checker", "collect_module_impl_facts", errors)
    if "allow_incomplete" in checker_collect or (
            "none => panic(" not in checker_collect):
        errors.append("ModuleImplFact collector allows typed owner miss")
    for function_name in ("check", "check_module"):
        body = _trait_method_function_body(
            sources, "checker", function_name, errors)
        collect_start = body.find("collect_module_impl_facts(")
        if collect_start >= 0:
            collect_slice = body[collect_start:collect_start + 180]
            if "sink.has_errors()" in collect_slice:
                errors.append(
                    f"{function_name} routes global error state into fact collection")
    return errors


F2_U1C0_PATHS = {
    "hir": REPO / "compiler" / "hir.ring",
    "env": REPO / "compiler" / "env.ring",
    "register": REPO / "compiler" / "infer_register.ring",
    "builtins": REPO / "compiler" / "builtins.ring",
    "ctx": REPO / "compiler" / "infer_ctx.ring",
    "helpers": REPO / "compiler" / "infer_helpers.ring",
    "infer": REPO / "compiler" / "infer.ring",
    "decl": REPO / "compiler" / "infer_decl.ring",
    "derive": REPO / "compiler" / "derive.ring",
    "exports": REPO / "compiler" / "exports.ring",
    "checker": REPO / "compiler" / "checker.ring",
}

F2_U1C0_WARNING_MESSAGE = (
    "catch on expression with no fail effect; handler will never execute")


def _u1c0_warning(
    file_name: str, line: int, col: int, end_line: int, end_col: int,
) -> Dict[str, Any]:
    return {
        "file": str(REPO / "compiler" / file_name),
        "diagnostic": {
            "code": "W0001",
            "severity": "warning",
            "message": F2_U1C0_WARNING_MESSAGE,
            "span": {
                "line": line, "col": col,
                "end_line": end_line, "end_col": end_col,
            },
            "context": {
                "kind": "other", "detail": "body has no fail effect",
            },
            "notes": [],
            "suggestions": [],
            "category": "warning",
        },
    }


F2_U1C0_PARSER_WARNINGS = (
    _u1c0_warning("parser.ring", 1778, 40, 1778, 88),
    _u1c0_warning("parser.ring", 1721, 33, 1721, 86),
    _u1c0_warning("parser.ring", 1731, 33, 1731, 82),
    _u1c0_warning("parser.ring", 1743, 41, 1743, 87),
    _u1c0_warning("parser.ring", 1751, 41, 1751, 90),
    _u1c0_warning("parser.ring", 806, 36, 806, 73),
)
F2_U1C0_CHECKER_WARNINGS = (*F2_U1C0_PARSER_WARNINGS,
    _u1c0_warning("infer.ring", 937, 38, 938, 74),
    _u1c0_warning("infer.ring", 674, 30, 674, 87),
    _u1c0_warning("infer.ring", 781, 30, 781, 87),
    _u1c0_warning("infer.ring", 3434, 22, 3434, 72),
    _u1c0_warning("infer_decl.ring", 165, 21, 166, 65),
)
F2_U1C0_EXPORTS_WARNINGS = F2_U1C0_PARSER_WARNINGS


def _warning_document(
    file_name: str, diagnostics: Sequence[Mapping[str, Any]],
) -> str:
    return json.dumps({
        "version": 1,
        "file": str(REPO / "compiler" / file_name),
        "diagnostics": list(diagnostics),
    }, separators=(",", ":"))


def llm_warning_document_sequence_probe_errors() -> List[str]:
    errors: List[str] = []
    first = F2_U1C0_PARSER_WARNINGS[0]
    second = _u1c0_warning("infer.ring", 937, 38, 938, 74)
    first_diag = first["diagnostic"]
    second_diag = second["diagnostic"]
    single = _warning_document("parser.ring", [first_diag]) + "\n"
    multi = (
        _warning_document("parser.ring", [first_diag]) + "\n" +
        _warning_document("infer.ring", [second_diag]) + "\n")
    if llm_warning_contract_error(single, [first]) is not None:
        errors.append("LLM warning probe rejected valid single document")
    if llm_warning_contract_error(multi, [first, second]) is not None:
        errors.append("LLM warning probe rejected valid multi-document sequence")

    duplicate_key = single.replace(
        '"version":1', '"version":1,"version":1', 1)
    if llm_warning_contract_error(duplicate_key, [first]) is None:
        errors.append("LLM warning probe accepted duplicate JSON key")
    if llm_warning_contract_error(single + "panic", [first]) is None:
        errors.append("LLM warning probe accepted trailing raw output")
    if llm_warning_contract_error(single[:-1], [first]) is None:
        errors.append("LLM warning probe accepted missing final newline")
    duplicate_diag = _warning_document(
        "parser.ring", [first_diag, first_diag]) + "\n"
    if llm_warning_contract_error(duplicate_diag, [first]) is None:
        errors.append("LLM warning probe accepted duplicate diagnostic")
    extra_warning = _warning_document(
        "parser.ring", [first_diag, F2_U1C0_PARSER_WARNINGS[1]["diagnostic"]]
    ) + "\n"
    if llm_warning_contract_error(extra_warning, [first]) is None:
        errors.append("LLM warning probe accepted extra W0001")
    w0002 = dict(first_diag)
    w0002["code"] = "W0002"
    if llm_warning_contract_error(
            _warning_document("parser.ring", [w0002]) + "\n", [first]) is None:
        errors.append("LLM warning probe accepted W0002")
    error_diag = dict(first_diag)
    error_diag["severity"] = "error"
    if llm_warning_contract_error(
            _warning_document("parser.ring", [error_diag]) + "\n", [first]
    ) is None:
        errors.append("LLM warning probe accepted error severity")
    return errors


def impl_export_closure_contract_errors(
    sources: dict[str, str],
) -> List[str]:
    """Cheap exact-owner export closure guard; behavior stays packet-owned."""
    errors: List[str] = []
    hir_source = sources.get("hir", "")
    fact_fields, fact_field_error = _f0_struct_fields(
        hir_source, "ModuleImplFact")
    if fact_field_error:
        errors.append(fact_field_error)
    elif fact_fields is not None and [
            name for _, name in fact_fields] != [
                "target", "provider_ref", "trait_ref", "owner_ref",
                "method_names", "public_inherent_method_names",
                "is_top_level"]:
        errors.append("impl export closure: ModuleImplFact typed inventory drifted")
    if "is_trait_impl" in hir_source:
        errors.append("impl export closure: ModuleImplFact retained second trait truth")

    checker_source = sources.get("checker", "")
    if "fn exact_module_impl_owner" in checker_source:
        errors.append("impl export closure: stale method-shape owner resolver remains")
    validate_carriers, validate_carriers_error = _f0_function_body(
        checker_source, "validate_impl_carriers")
    if validate_carriers_error:
        errors.append(validate_carriers_error)
    elif validate_carriers is not None and not all(
            token in validate_carriers for token in (
                "find_impl_by_provider(",
                "env.trait_reg, target_type, trait_ref, provider_ref",
                "optional_symbol_ref_same(owner.trait_ref, trait_ref)",
                "owner.method_schemes.contains_key(name)",
                "typed owner is missing",
                "validate_impl_carriers(env, inner)",
            )):
        errors.append("impl export closure: HIR carrier validator is incomplete")

    collect_body, collect_error = _f0_function_body(
        checker_source, "collect_module_impl_facts")
    if collect_error:
        errors.append(collect_error)
    elif collect_body is not None:
        for token in (
                "find_impl_by_provider(",
                "env.trait_reg, target_type, trait_ref, provider_ref",
                "provider_ref: provider_ref", "trait_ref: trait_ref",
                "owner_ref: owner_ref",
                "optional_symbol_ref_same(",
                "owner.method_schemes.contains_key(method_name)",
                "HDecl::Fn { name, is_pub, .. }",
                "if trait_ref.is_none() && is_pub",
                "public_inherent_method_names.push(name)"):
            if token not in collect_body:
                errors.append(
                    f"impl export closure: typed collector misses {token!r}")
        for forbidden in (
                "trait_impls.get(", "method_origins.get(", "MethodOrigin",
                "exact_module_impl_owner("):
            if forbidden in collect_body:
                errors.append(
                    f"impl export closure: collector re-resolves by {forbidden!r}")
        if "if trait_name.is_some() || method_names.len() > 0" not in collect_body:
            errors.append("impl export closure: empty inherent skip is not explicit")
        if not all(token in collect_body for token in (
            "HDecl::ModBlock { decls: mod_decls, is_pub, .. }",
            "if is_pub {",
            "env, mod_decls, false, facts",
        )):
            errors.append("impl export closure: public/private nested inventory is open")
        if "allow_incomplete" in collect_body or "sink.has_errors()" in collect_body:
            errors.append("impl export closure: collector retained global error bypass")
        if "none => panic(" not in collect_body:
            errors.append("impl export closure: typed owner miss is not internal")

    env_source = sources.get("env", "")
    owner_shape_body, owner_shape_error = _f0_function_body(
        env_source, "impl_entry_owner_shape_same")
    if owner_shape_error:
        errors.append(owner_shape_error)
    elif owner_shape_body is not None and not all(
            token in owner_shape_body for token in (
                "left.target_type_name == right.target_type_name",
                "optional_string_same(left.trait_name, right.trait_name)",
                "optional_symbol_ref_same(left.trait_ref, right.trait_ref)",
                "string_list_same(left.type_params, right.type_params)",
                "int_list_same(left.type_param_vars, right.type_param_vars)",
                "frozen_impl_predicate_set_same(left.predicates, right.predicates)",
                "assoc_type_map_same(left.assoc_types, right.assoc_types)",
            )):
        errors.append("impl export closure: final-owner shape equality is incomplete")
    owner_same_body, owner_same_error = _f0_function_body(
        env_source, "impl_entry_final_same")
    if owner_same_error:
        errors.append(owner_same_error)
    elif owner_same_body is not None and not all(
            token in owner_same_body for token in (
                "optional_impl_provider_ref_same(",
                "left.provider_ref, right.provider_ref",
                "impl_entry_owner_shape_same(left, right)",
                "string_list_same(left.method_names, right.method_names)",
                "method_core_map_same(left.method_schemes, right.method_schemes)",
                "method_ref_map_same(left.method_refs, right.method_refs)",
                "method_intrinsic_map_same(",
                "delegate_plan_state_same(left.delegate_plan, right.delegate_plan)",
            )):
        errors.append("impl export closure: shared final-owner equality is incomplete")

    exports_source = sources.get("exports", "")
    if any(token in exports_source for token in (
            "MethodOrigin", "method_origins", "method_origin_same",
            "insert_exact_method_origin", "map_clone(origins)")):
        errors.append("impl export closure: whole target method map merge remains")
    for helper_name in (
        "copy_inline_export", "extract_decl_export",
        "copy_exported_name", "export_impl_facts",
    ):
        helper_body, helper_error = _f0_function_body(
            exports_source, helper_name)
        if helper_error:
            errors.append(helper_error)
        elif helper_body is not None and (
                "method_index.insert(" in helper_body or
                "append_owner_method_indexes(" in helper_body):
            errors.append(
                f"impl export closure: {helper_name} produces method indexes")
    owner_shape_body, owner_shape_error = _f0_function_body(
        exports_source, "method_ref_matches_owner")
    if owner_shape_error:
        errors.append(owner_shape_error)
    elif owner_shape_body is not None and not all(token in owner_shape_body for token in (
        "impl_method_ref_owner(method_ref), owner_ref",
        "owner.method_refs.get(impl_method_ref_name(method_ref))",
        "impl_method_ref_same(expected, method_ref)",
    )):
        errors.append("impl export closure: method index owner shape is not exact")
    insert_body, insert_error = _f0_function_body(
        exports_source, "insert_exact_method_ref")
    if insert_error:
        errors.append(insert_error)
    elif insert_body is not None and not all(token in insert_body for token in (
        "some(existing) => if !impl_method_ref_same(existing, method_ref)",
        "distinct identities share one method index",
    )):
        errors.append("impl export closure: method map union can silently overwrite")
    dedupe_body, dedupe_error = _f0_function_body(
        exports_source, "append_exact_impl_owner")
    if dedupe_error:
        errors.append(dedupe_error)
    elif dedupe_body is not None and not all(token in dedupe_body for token in (
        "impl_entry_exact_key_same(existing, owner)",
        "!impl_entry_final_same(existing, owner)",
        "same-provider owner structure drifted",
    )):
        errors.append("impl export closure: same-origin owner drift is not rejected")
    indexes_body, indexes_error = _f0_function_body(
        exports_source, "append_owner_method_indexes")
    if indexes_error:
        errors.append(indexes_error)
    elif indexes_body is not None and not all(token in indexes_body for token in (
        "owner.method_schemes.entries()",
        "for core_entry in sorted_cores",
        "if !allowed_method_names.contains(method_name) { continue }",
        "!method_ref_matches_owner(method_ref, owner)",
        "insert_exact_method_ref(",
    )):
        errors.append("impl export closure: owner indexes are not same-origin exact")
    elif indexes_body is not None and "if method_name" in indexes_body:
        errors.append("impl export closure: owner index production is conditional")
    facts_body, facts_error = _f0_function_body(
        exports_source, "export_impl_facts")
    if facts_error:
        errors.append(facts_error)
    elif facts_body is not None:
        if not all(token in facts_body for token in (
            "find_impl_by_provider(",
            "env.trait_reg, fact.target,",
            "fact.trait_ref, fact.provider_ref",
            "registered, fact.owner_ref",
            "append_exact_impl_owner(owner, fact_owners)",
        )):
            errors.append("impl export closure: fact export loses exact owner")
        if not all(token in facts_body for token in (
            "let mut seen_fact_owners: List<ImplEntry> = []",
            "impl_entry_exact_key_same(seen, owner)",
            "user impl fact was exported twice",
        )):
            errors.append("impl export closure: user fact is not consumed once")
        if "append_owner_method_indexes(" in facts_body or (
                "method_index.insert(" in facts_body):
            errors.append("impl export closure: fact helper produces method indexes")
        for token in (
                "fact.trait_ref.is_some() &&",
                "fact.public_inherent_method_names.len() != 0",
                "fact.method_names.contains(public_name)"):
            if token not in facts_body:
                errors.append(
                    f"impl export closure: visibility projection misses {token!r}")

    extract_body, extract_error = _f0_function_body(
        exports_source, "extract_exports")
    if extract_error:
        errors.append(extract_error)
    elif extract_body is not None:
        if not all(token in extract_body for token in (
            "let mut fact_owners: List<ImplEntry> = []",
            "for owner in fact_owners",
            "append_exact_impl_owner(owner, trait_impls)",
        )):
            errors.append("impl export closure: final owner union omits module facts")
        map_at = extract_body.find(
            "let mut method_index: Map<Str, Map<Str, ImplMethodRef>> = map_new()")
        final_union_at = extract_body.find("for owner in trait_impls")
        closed_owner_at = extract_body.rfind(
            "append_exact_impl_owner(impl_, trait_impls)")
        if (map_at < 0 or final_union_at < 0 or closed_owner_at < 0 or
                map_at < closed_owner_at or map_at > final_union_at):
            errors.append("impl export closure: index map is not fresh after owner union")
        if extract_body.count("target_exported &&") != 2 or (
                "exported_trait_ids.contains(name)" not in extract_body):
            errors.append("impl export closure: trait impl visibility is not target+trait")
        if "exported_owner_method_names(owner, inherent_methods)" not in extract_body:
            errors.append("impl export closure: callable index ignores inherent visibility")
        if "validate_impl_export_closure(\n        trait_impls, method_index, inherent_methods)" not in extract_body:
            errors.append("impl export closure: final owner/index relation is unvalidated")
    validate_body, validate_error = _f0_function_body(
        exports_source, "validate_impl_export_closure")
    if validate_error:
        errors.append(validate_error)
    elif validate_body is not None and not all(token in validate_body for token in (
        "!owner.method_schemes.contains_key(method_name)",
        "if matches != 1",
        "let allowed = exported_owner_method_names(owner, inherent_methods)",
        "if !allowed.contains(method_name) { continue }",
        "for core_entry in owner.method_schemes.entries()",
        "owner core has no exported index",
        "owner core index is not exact",
    )):
        errors.append("impl export closure: final validator is not bidirectional")

    inject_body, inject_error = _f0_function_body(
        checker_source, "inject_module_exports")
    if inject_error:
        errors.append(inject_error)
    elif inject_body is not None and not all(token in inject_body for token in (
        "find_impl_by_provider(",
        "impl_owner_ref_trait(owner_ref)",
        "impl_owner_ref_provider(owner_ref)",
        "some(expected) => if !impl_method_ref_same(",
        "expected, method_ref",
        "impl hydration: exported index has no owner core",
        "impl hydration: exported index owner is missing",
    )):
        errors.append("impl export closure: hydration treats missing owner as ambiguity")
    if "report_hydrated_method_collision" in checker_source:
        errors.append("impl export closure: stale missing-owner E0504 helper remains")
    return errors


def impl_export_closure_mutation_errors(
    sources: dict[str, str],
) -> List[str]:
    errors: List[str] = []
    mutations = (
        ("checker", "validate_impl_carriers",
         "find_impl_by_provider(", "find_impl_by_origin(",
         "HIR carrier validator is incomplete"),
        ("checker", "collect_module_impl_facts",
         "find_impl_by_provider(", "find_impl_by_origin(",
         "typed collector misses"),
        ("checker", "collect_module_impl_facts",
         "owner.method_schemes.contains_key(method_name)",
         "false",
         "typed collector misses"),
        ("checker", "collect_module_impl_facts",
         "if trait_ref.is_none() && is_pub",
         "if is_pub",
         "typed collector misses"),
        ("checker", "collect_module_impl_facts",
         "owner_ref: owner_ref", "owner_ref: wrong_owner_ref",
         "typed collector misses"),
        ("checker", "collect_module_impl_facts",
         "if trait_name.is_some() || method_names.len() > 0", "if true",
         "empty inherent skip is not explicit"),
        ("checker", "collect_module_impl_facts",
         "if is_pub {", "if true {",
         "public/private nested inventory is open"),
        ("checker", "collect_module_impl_facts",
         "none => panic(", "none => {} // swallowed typed owner miss\n                panic(",
         "typed owner miss is not internal"),
        ("exports", "method_ref_matches_owner",
         "impl_method_ref_owner(method_ref), owner_ref", "owner_ref, owner_ref",
         "method index owner shape is not exact"),
        ("exports", "method_ref_matches_owner",
         "owner.method_refs.get(impl_method_ref_name(method_ref))",
         "owner.method_refs.get(\"wrong\")",
         "method index owner shape is not exact"),
        ("exports", "insert_exact_method_ref",
         "!impl_method_ref_same(existing, method_ref)", "false",
         "method map union can silently overwrite"),
        ("exports", "append_exact_impl_owner",
         "impl_entry_exact_key_same(existing, owner)", "true",
         "same-origin owner drift is not rejected"),
        ("exports", "append_exact_impl_owner",
         "!impl_entry_final_same(existing, owner)", "false",
         "same-origin owner drift is not rejected"),
        ("env", "impl_entry_owner_shape_same",
         "frozen_impl_predicate_set_same(left.predicates, right.predicates)",
         "true", "final-owner shape equality is incomplete"),
        ("env", "impl_entry_owner_shape_same",
         "assoc_type_map_same(left.assoc_types, right.assoc_types)",
         "true", "final-owner shape equality is incomplete"),
        ("env", "impl_entry_final_same",
         "string_list_same(left.method_names, right.method_names)",
         "true", "shared final-owner equality is incomplete"),
        ("env", "impl_entry_final_same",
         "method_core_map_same(left.method_schemes, right.method_schemes)",
         "true", "shared final-owner equality is incomplete"),
        ("env", "impl_entry_final_same",
         "method_ref_map_same(left.method_refs, right.method_refs)",
         "true", "shared final-owner equality is incomplete"),
        ("env", "impl_entry_final_same",
         "method_intrinsic_map_same(\n            left.method_intrinsics, right.method_intrinsics)",
         "true", "shared final-owner equality is incomplete"),
        ("exports", "append_owner_method_indexes",
         "!method_ref_matches_owner(method_ref, owner)", "false",
         "owner indexes are not same-origin exact"),
        ("exports", "export_impl_facts",
         "fact.trait_ref, fact.provider_ref",
         "fact.trait_ref, wrong_provider_ref",
         "fact export loses exact owner"),
        ("exports", "export_impl_facts",
         "impl_entry_exact_key_same(seen, owner)", "false",
         "user fact is not consumed once"),
        ("exports", "copy_exported_name",
         "types.insert(local_name, def)",
         "types.insert(local_name, def)\n            method_index.insert(canonical_type, map_clone(source.method_index.get(canonical_type).unwrap()))",
         "copy_exported_name produces method indexes"),
        ("exports", "export_impl_facts",
         "append_exact_impl_owner(owner, fact_owners)",
         "append_exact_impl_owner(owner, fact_owners)\n        append_owner_method_indexes(owner, env.trait_reg.method_index, fact.method_names, method_index)",
         "fact helper produces method indexes"),
        ("exports", "extract_exports",
         "for owner in fact_owners {",
         "for owner in [] {",
         "final owner union omits module facts"),
        ("exports", "extract_exports",
         "some(name) => target_exported &&\n                exported_trait_ids.contains(name)",
         "some(name) => target_exported ||\n                exported_trait_ids.contains(name)",
         "trait impl visibility is not target+trait"),
        ("exports", "append_owner_method_indexes",
         "for core_entry in sorted_cores {",
         "for core_entry in [] {",
         "owner indexes are not same-origin exact"),
        ("exports", "extract_exports",
         "validate_impl_export_closure(\n        trait_impls, method_index, inherent_methods)", "{}",
         "final owner/index relation is unvalidated"),
        ("exports", "validate_impl_export_closure",
         "!owner.method_schemes.contains_key(method_name)", "false",
         "final validator is not bidirectional"),
        ("exports", "validate_impl_export_closure",
         "if matches != 1", "if false",
         "final validator is not bidirectional"),
        ("exports", "validate_impl_export_closure",
         "for core_entry in owner.method_schemes.entries()",
         "for core_entry in []",
         "final validator is not bidirectional"),
        ("exports", "validate_impl_export_closure",
         "panic(\"impl export closure: owner core index is not exact\")",
         "{}", "final validator is not bidirectional"),
        ("checker", "inject_module_exports",
         "panic(\n                                \"impl hydration: exported index has no owner core\")",
         "{}", "hydration treats missing owner as ambiguity"),
        ("checker", "inject_module_exports",
         "panic(\n                        \"impl hydration: exported index owner is missing\")",
         "{}", "hydration treats missing owner as ambiguity"),
    )
    killed = 0
    for source_name, function_name, anchor, replacement, expected in mutations:
        mutated_source, mutation_error = _f0_mutate_function_once(
            sources[source_name], function_name, anchor, replacement)
        if mutation_error:
            errors.append(
                f"impl export closure mutation {source_name}.{function_name}: "
                f"{mutation_error}")
            continue
        assert mutated_source is not None
        mutated = dict(sources)
        mutated[source_name] = mutated_source
        findings = impl_export_closure_contract_errors(mutated)
        if not any(expected in finding for finding in findings):
            errors.append(
                f"impl export closure mutation {source_name}.{function_name} "
                f"missed {expected!r}: {findings!r}")
        else:
            killed += 1

    hir_source = sources["hir"]
    anchor = "    pub owner_ref: ImplOwnerRef,\n"
    if hir_source.count(anchor) != 1:
        errors.append(
            f"impl export closure HIR mutation anchor count was "
            f"{hir_source.count(anchor)}")
    else:
        mutated = dict(sources)
        mutated["hir"] = hir_source.replace(anchor, "", 1)
        findings = impl_export_closure_contract_errors(mutated)
        expected = "ModuleImplFact typed inventory drifted"
        if not any(expected in finding for finding in findings):
            errors.append(
                f"impl export closure HIR mutation missed {expected!r}: "
                f"{findings!r}")
        else:
            killed += 1
    visibility_anchor = "    pub public_inherent_method_names: List<Str>,\n"
    if hir_source.count(visibility_anchor) != 1:
        errors.append(
            f"impl export closure visibility mutation anchor count was "
            f"{hir_source.count(visibility_anchor)}")
    else:
        mutated = dict(sources)
        mutated["hir"] = hir_source.replace(visibility_anchor, "", 1)
        findings = impl_export_closure_contract_errors(mutated)
        expected = "ModuleImplFact typed inventory drifted"
        if not any(expected in finding for finding in findings):
            errors.append(
                f"impl export closure visibility mutation missed {expected!r}: "
                f"{findings!r}")
        else:
            killed += 1
    if killed != F2_IMPL_EXPORT_CLOSURE_MUTATION_COUNT:
        errors.append(
            f"impl export closure killed {killed} mutations, expected "
            f"{F2_IMPL_EXPORT_CLOSURE_MUTATION_COUNT}")
    return errors


def impl_predicate_u1c0_contract_errors(
    sources: dict[str, str],
) -> List[str]:
    """Cheap U1c0 structure guard; candidate behavior is an external gate."""
    errors: List[str] = []
    combined = "\n".join(sources.values())
    for forbidden in (
        "ImplDictBound",
        "instantiate_impl_dict_requirements",
        "trait_reg.impl_methods",
        "install_method_scheme",
        "normalize_impl_bounds",
    ):
        if forbidden in combined:
            errors.append(f"U1c0 retired predicate authority remains: {forbidden}")

    env_source = sources.get("env", "")
    for token in (
        "pub struct TypedImplPredicate",
        "pub struct FrozenImplPredicateSet",
        "pub struct ImplMethodSchemeCore",
        "pub predicates: FrozenImplPredicateSet",
        "pub method_schemes: Map<Str, ImplMethodSchemeCore>",
        "pub method_refs: Map<Str, ImplMethodRef>",
        "pub owner_ref: ImplOwnerRef?",
        "pub trait_name: Str?",
        "pub type_param_vars: List<Int>",
        "pub fn instantiate_impl_runtime_requirements",
    ):
        if token not in env_source:
            errors.append(f"U1c0 env schema missing {token!r}")
    if "pub impl_methods:" in env_source:
        errors.append("U1c0 TraitRegistry still exposes flat method schemes")

    core_body, core_error = extract_ring_function_body(
        env_source, "impl_method_core_from_scheme")
    if core_error:
        errors.append(core_error)
    elif core_body is not None and not all(token in core_body for token in (
        "scheme.bounds.len() != 0",
        "method-owned bounds are unsupported",
    )):
        errors.append("U1c0 core conversion does not reject method bounds")

    freeze_body, freeze_error = extract_ring_function_body(
        env_source, "freeze_impl_predicate_set")
    if freeze_error:
        errors.append(freeze_error)
    elif freeze_body is not None and not all(token in freeze_body for token in (
        "subject does not match owner type variables",
        "duplicate owner predicate",
        "expanded path has no direct root",
    )):
        errors.append("U1c0 frozen predicate validation is incomplete")
    add_impl_body, add_impl_error = extract_ring_function_body(
        env_source, "add_impl")
    if add_impl_error:
        errors.append(add_impl_error)
    elif add_impl_body is not None and "validate_impl_entry(reg, entry)" not in add_impl_body:
        errors.append("U1c0 owner insertion bypasses relational validation")
    if "expanded predicate path is not a supertrait edge" not in env_source:
        errors.append("U1c0 expanded predicate paths are not relationally validated")
    validate_owner_body, validate_owner_error = extract_ring_function_body(
        env_source, "validate_impl_entry")
    if validate_owner_error:
        errors.append(validate_owner_error)
    elif validate_owner_body is not None and not all(
            token in validate_owner_body for token in (
                "entry.method_refs.len() != entry.method_schemes.len()",
                "impl_owner_ref_provider(owner), provider",
                "impl owner: typed owner/method closure drifted")):
        errors.append("U1c0 final owner exact closure is incomplete")
    for retired in (
            "ImplOwnerState", "ProvisionalPrelude",
            "finalize_provisional_impl_owner", "find_impl_by_origin"):
        if retired in env_source:
            errors.append(f"U1c0 retired provisional authority returned: {retired}")

    register_source = sources.get("register", "")
    for token in (
        "fn freeze_source_impl_predicates",
        "BoundShapeContext::ImplMethodBound",
        "BoundShapeContext::ProtocolImplBound",
        "fn collect_supertraits_dfs",
        "impl_owner_fn_bounds",
        "merge_delegate_owner_predicates",
    ):
        if token not in register_source:
            errors.append(f"U1c0 registration missing {token!r}")
    super_body, super_error = extract_ring_function_body(
        register_source, "collect_all_supertraits")
    if super_error:
        errors.append(super_error)
    elif super_body is not None and "let mut stack: List<Str>" in super_body:
        errors.append("U1c0 supertrait closure still uses LIFO authority")
    if "ctx, mtps, BoundShapeContext::ImplMethodBound, method_span" not in register_source:
        errors.append("U1c0 impl method bound gate is not attached to method registration")
    if "some(found) => merge_delegate_owner_predicates(" not in register_source:
        errors.append("U1c0 delegate does not merge the selected field owner")
    canonical_body, canonical_error = extract_ring_function_body(
        register_source, "register_impl_canonical")
    if canonical_error:
        errors.append(canonical_error)
    elif canonical_body is not None and not all(token in canonical_body for token in (
            "let tv = ctx.env.fresh_var()",
            "provider_ref: some(provider_ref)",
            "owner_ref: some(owner_ref)",
            "add_impl(ctx.env.trait_reg, owner_entry)")):
        errors.append("U1c0 source impl does not publish one exact final owner")
    for retired in (
            "find_impl_by_origin(", "finalize_provisional_impl_owner(",
            "ImplOwnerState::ProvisionalPrelude"):
        if retired in register_source:
            errors.append(f"U1c0 registration retained provisional route {retired!r}")
    for function_name in (
        "register_fn_common",
        "register_effect",
        "register_type_alias",
        "register_effect_alias",
    ):
        body, error = extract_ring_function_body(register_source, function_name)
        if error:
            errors.append(error)
        elif body is not None and "validate_type_param_bound_shapes(" not in body:
            errors.append(f"U1c0 {function_name} bypasses TypeBound shape validation")
    for token in (
        "protocol lowering does not yet consume",
        "protocol lowering has not consumed nested impl predicates",
    ):
        if token not in register_source:
            errors.append(f"U1c0 protocol fail-loud wording missing {token!r}")

    builtins = sources.get("builtins", "")
    for retired in (
            "<std-predecl>", "ImplOwnerState", "ProvisionalPrelude",
            "seed_std_hof_owners", "seed_std_hof_owner",
            "require_std_hof_seed"):
        if retired in builtins:
            errors.append(f"U1c0 provisional builtin authority returned: {retired}")
    install_builtin_body, install_builtin_error = extract_ring_function_body(
        builtins, "install_builtin_method_owner")
    if install_builtin_error:
        errors.append(install_builtin_error)
    elif install_builtin_body is not None and not all(
            token in install_builtin_body for token in (
                "method_schemes: map_clone(cores)",
                "method_refs: method_refs",
                "method_intrinsics: map_clone(method_intrinsics)",
                "provider_ref: some(provider_ref)",
                "owner_ref: some(owner_ref)")):
        errors.append("U1c0 builtin owner exact closure is incomplete")
    register_hof_body, register_hof_error = extract_ring_function_body(
        builtins, "register_hof_intrinsics")
    if register_hof_error:
        errors.append(register_hof_error)
    elif register_hof_body is not None:
        if register_hof_body.count("register_option_hof(env, sink)") != 1:
            errors.append("U1c0 normal HOF registration lost exact Option builtin")
        for forbidden_call in (
            "register_list_hof(", "register_map_hof(", "register_set_hof("):
            if forbidden_call in register_hof_body:
                errors.append("U1c0 normal path publishes std HOF method cores")
    fallback_body, fallback_error = extract_ring_function_body(
        builtins, "finalize_std_hof_fallbacks")
    if fallback_error:
        errors.append(fallback_error)
    elif fallback_body is not None and not all(token in fallback_body for token in (
        "register_list_hof(env, sink)",
        "register_map_hof(env, sink)",
        "register_set_hof(env, sink)",
    )):
        errors.append("U1c0 no-std fallback does not finalize all std HOF owners")
    for function_name in (
        "register_list_hof", "register_map_hof", "register_set_hof"):
        body, error = extract_ring_function_body(builtins, function_name)
        if error:
            errors.append(error)
        elif body is not None and not all(token in body for token in (
                "env.fresh_var_id()", "install_builtin_method_owner(")):
            errors.append(
                f"U1c0 {function_name} does not mint one independent final owner")
        elif function_name == "register_list_hof" and body is not None and (
                "let t_id = env.fresh_var_id()" not in body):
            errors.append("U1c0 List fallback lost its exact fresh owner variable")

    ctx_source = sources.get("ctx", "")
    for token in (
        "ImplOwnerEvidenceSource",
        "resolve_impl_owner_evidence",
        "resolve_or_defer_dicts_from_impl_owner",
        "impl_predicate_constraints_satisfied",
    ):
        if token not in ctx_source:
            errors.append(f"U1c0 evidence consumer missing {token!r}")
    if "source: PendingEvidenceSource::ImplOwnerEvidenceSource {" not in ctx_source:
        errors.append("U1c0 pending obligation does not retain the exact owner")

    helpers = sources.get("helpers", "")
    if "ctx.env.trait_reg.method_index.get(type_name)" not in helpers or (
        "let owner_ref = impl_method_ref_owner(method_ref)" not in helpers or
        "find_impl_by_provider(" not in helpers
    ):
        errors.append("U1c0 method lookup does not follow the exact owner index")
    infer_source = sources.get("infer", "")
    if "resolve_or_defer_dicts_from_impl_owner(" not in infer_source:
        errors.append("U1c0 method call does not consume owner predicates")
    decl_source = sources.get("decl", "")
    if "let impl_bounds = impl_owner_fn_bounds(impl_owner)" not in decl_source:
        errors.append("U1c0 impl checking reconstructs predicates from AST")
    derive_source = sources.get("derive", "")
    if "struct DerivedPredicatePlan" not in derive_source or (
        "freeze_impl_predicate_set(" not in derive_source
    ):
        errors.append("U1c0 derive does not freeze its transient plan")
    exports_source = sources.get("exports", "")
    if "pub impl_methods:" in exports_source or "source.impl_methods" in exports_source:
        errors.append("U1c0 exports retain a flat method scheme copy")
    checker_source = sources.get("checker", "")
    owner_add = checker_source.find("add_impl(ctx.env.trait_reg, impl_)")
    index_install = checker_source.find("install_method_core(", owner_add)
    if owner_add < 0 or index_install < 0 or owner_add > index_install:
        errors.append("U1c0 hydration does not install owners before indexes")
    if "assert_no_provisional_impl_owners" in checker_source:
        errors.append("U1c0 checker retained provisional close authority")
    load_prelude_body, load_prelude_error = extract_ring_function_body(
        checker_source, "load_prelude")
    if load_prelude_error:
        errors.append(load_prelude_error)
    elif load_prelude_body is not None:
        if load_prelude_body.count("finalize_std_hof_fallbacks(") != 1:
            errors.append("U1c0 no-std fallback branch is not unique")
        fallback_at = load_prelude_body.find("none => {")
        finalize_at = load_prelude_body.find("finalize_std_hof_fallbacks(")
        if fallback_at < 0 or finalize_at < fallback_at:
            errors.append("U1c0 std-present path can reach late HOF fallback")
    return errors


F2_U1C0_SOURCE_CONTRACT_MUTATIONS = (
    ("env", "pub predicates: FrozenImplPredicateSet", "pub predicates: List<TypedImplPredicate>"),
    ("env", "pub method_schemes: Map<Str, ImplMethodSchemeCore>", "pub method_schemes: Map<Str, TypeScheme>"),
    ("env", "scheme.bounds.len() != 0", "false"),
    ("env", "panic(\"impl predicate: duplicate owner predicate\")", "{}"),
    ("register", "ctx, mtps, BoundShapeContext::ImplMethodBound, method_span", "ctx, mtps, BoundShapeContext::OrdinaryBound, method_span"),
    ("register", "BoundShapeContext::ProtocolImplBound", "BoundShapeContext::ImplOwnerBound"),
    ("register", "provider_ref: some(provider_ref),\n            trait_ref: resolved_trait_ref,\n            owner_ref: some(owner_ref)", "provider_ref: none,\n            trait_ref: resolved_trait_ref,\n            owner_ref: some(owner_ref)"),
    ("decl", "let impl_bounds = impl_owner_fn_bounds(impl_owner)", "let impl_bounds: List<FnBoundsEntry> = []"),
    ("register", "some(found) => merge_delegate_owner_predicates(", "some(found) => freeze_impl_predicate_set("),
    ("env", "entry.method_refs.len() != entry.method_schemes.len()", "false"),
    ("env", "impl_owner_ref_provider(owner), provider", "provider, provider"),
    ("builtins", "method_intrinsics: map_clone(method_intrinsics),\n        provider_ref: some(provider_ref)", "method_intrinsics: map_clone(method_intrinsics),\n        provider_ref: none"),
    ("builtins", "trait_ref: trait_ref,\n        owner_ref: some(owner_ref),\n        delegate_plan", "trait_ref: trait_ref,\n        owner_ref: none,\n        delegate_plan"),
    ("builtins", "method_schemes: map_clone(cores),\n        method_refs: method_refs,\n        method_intrinsics: map_clone(method_intrinsics)", "method_schemes: map_clone(cores),\n        method_refs: map_new(),\n        method_intrinsics: map_clone(method_intrinsics)"),
    ("builtins", "pub fn register_hof_intrinsics(mut env: TypeEnv, sink: CollectingSink) {", "pub fn register_hof_intrinsics(mut env: TypeEnv, sink: CollectingSink) {\n    register_list_hof(env, sink)"),
    ("builtins", "register_option_hof(env, sink)", "register_list_hof(env, sink)"),
    ("builtins", "register_list_hof(env, sink)\n", "{}\n"),
    ("builtins", "register_map_hof(env, sink)\n", "{}\n"),
    ("builtins", "register_set_hof(env, sink)\n", "{}\n"),
    ("builtins", "fn register_list_hof(mut env: TypeEnv, sink: CollectingSink) {\n    let mut methods: Map<Str, TypeScheme> = map_new()\n    // map: (List<T>, (T) -> U / e) -> List<U> / e\n    let t_id = env.fresh_var_id()", "fn register_list_hof(mut env: TypeEnv, sink: CollectingSink) {\n    let mut methods: Map<Str, TypeScheme> = map_new()\n    // map: (List<T>, (T) -> U / e) -> List<U> / e\n    let t_id = 0"),
    ("checker", "finalize_std_hof_fallbacks(ctx.env, ctx.sink)", "{}"),
    ("checker", "some(std_dir) => {", "some(std_dir) => {\n            finalize_std_hof_fallbacks(ctx.env, ctx.sink)"),
    ("register", "span: Span, check_dup: Bool, track_mut_params: Bool, track_fn_bounds: Bool\n) {\n    validate_type_param_bound_shapes(\n        ctx, type_params, BoundShapeContext::OrdinaryBound, span)", "span: Span, check_dup: Bool, track_mut_params: Bool, track_fn_bounds: Bool\n) {\n    {}"),
    ("register", "ops: List<EffectOpDecl>, span: Span, decl_index: Int\n) {\n    validate_type_param_bound_shapes(\n        ctx, type_params, BoundShapeContext::OrdinaryBound, span)", "ops: List<EffectOpDecl>, span: Span, decl_index: Int\n) {\n    {}"),
    ("register", "type_expr: TypeExpr, span: Span\n) {\n    validate_type_param_bound_shapes(\n        ctx, type_params, BoundShapeContext::OrdinaryBound, span)", "type_expr: TypeExpr, span: Span\n) {\n    {}"),
    ("register", "fn register_effect_alias(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, effects: List<EffectExpr>, span: Span) {\n    validate_type_param_bound_shapes(\n        ctx, type_params, BoundShapeContext::OrdinaryBound, span)", "fn register_effect_alias(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, effects: List<EffectExpr>, span: Span) {\n    {}"),
    ("register", "that protocol lowering does not yet consume", "that exact dictionary evidence cannot preserve"),
    ("register", "protocol lowering has not consumed nested impl predicates", "nested impl predicates are not yet representable in ImplEntry"),
    ("ctx", "source: PendingEvidenceSource::ImplOwnerEvidenceSource {", "source: PendingEvidenceSource::SchemeEvidenceSource("),
    ("helpers", "ctx.env.trait_reg.method_index.get(type_name)", "ctx.env.trait_reg.impl_methods.get(type_name)"),
    ("infer", "resolve_or_defer_dicts_from_impl_owner(", "resolve_or_defer_dicts_from_scheme("),
    ("derive", "freeze_impl_predicate_set(", "empty_frozen_impl_predicate_set("),
    ("exports", "pub trait_impls: List<ImplEntry>,", "pub trait_impls: List<ImplEntry>,\n    pub impl_methods: Map<Str, Map<Str, TypeScheme>>,"),
    ("checker", "add_impl(ctx.env.trait_reg, impl_)", "{}"),
    ("env", "pub fn add_impl(mut reg: TraitRegistry, entry: ImplEntry) {\n    validate_impl_entry(reg, entry)", "pub fn add_impl(mut reg: TraitRegistry, entry: ImplEntry) {\n    {}"),
)


def impl_predicate_u1c0_source_errors() -> List[str]:
    errors: List[str] = []
    sources: dict[str, str] = {}
    for name, path in F2_U1C0_PATHS.items():
        try:
            sources[name] = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            errors.append(f"cannot read {display_path(path)}: {exc}")
    if errors:
        return errors
    errors.extend(llm_warning_document_sequence_probe_errors())
    errors.extend(impl_predicate_u1c0_contract_errors(sources))
    errors.extend(impl_export_closure_contract_errors(sources))
    errors.extend(impl_export_closure_mutation_errors(sources))
    killed = 0
    for source_name, old, new in F2_U1C0_SOURCE_CONTRACT_MUTATIONS:
        source = sources[source_name]
        if source.count(old) != 1:
            errors.append(
                f"U1c0 mutation anchor {source_name}:{old!r} count was "
                f"{source.count(old)}")
            continue
        mutated = dict(sources)
        mutated[source_name] = source.replace(old, new, 1)
        findings = impl_predicate_u1c0_contract_errors(mutated)
        if not findings:
            errors.append(f"U1c0 source mutation escaped: {source_name}:{old!r}")
        else:
            killed += 1
    if killed != F2_U1C0_SOURCE_CONTRACT_MUTATION_COUNT:
        errors.append(
            f"U1c0 killed {killed} mutations, expected "
            f"{F2_U1C0_SOURCE_CONTRACT_MUTATION_COUNT}")
    return errors


def impl_predicate_u1c0_source_check_errors(ring_exe: str) -> List[str]:
    errors: List[str] = []
    compiler = Path(ring_exe)
    before = _sha256_file(compiler)
    environment = dict(_controlled_environment(ring_exe))
    for source_path in (
        F2_U1C0_PATHS["env"], F2_U1C0_PATHS["builtins"],
        F2_U1C0_PATHS["hir"], F2_U1C0_PATHS["checker"],
        F2_U1C0_PATHS["exports"],
    ):
        timeout_seconds = (
            600 if source_path == F2_U1C0_PATHS["checker"] else 120)
        expected_warnings: Optional[Sequence[Mapping[str, Any]]] = None
        if source_path == F2_U1C0_PATHS["checker"]:
            expected_warnings = F2_U1C0_CHECKER_WARNINGS
        elif source_path == F2_U1C0_PATHS["exports"]:
            expected_warnings = F2_U1C0_EXPORTS_WARNINGS
        error = _f1_run_ring_check(
            ring_exe, source_path, environment, timeout_seconds,
            expected_warnings)
        if error:
            errors.append(error)
    if _sha256_file(compiler) != before:
        errors.append("pinned Ring compiler changed across F2 U1c0 checks")
    return errors


def impl_predicate_u1c0_no_std_errors(ring_exe: str) -> List[str]:
    errors: List[str] = []
    compiler = Path(ring_exe).resolve(strict=True)
    before = _sha256_file(compiler)
    fixture = CASES_DIR / "no_std_hof_fallback.ring"
    environment = dict(_controlled_environment(str(compiler)))
    with tempfile.TemporaryDirectory(prefix="ring_u1c0_no_std_") as temp:
        cwd = Path(temp).resolve(strict=True)
        if (cwd / "std").exists() or (cwd.parent / "std").exists():
            return ["U1c0 no-std check root unexpectedly contains std"]
        completed = subprocess.run(
            [str(compiler), "check", str(fixture)],
            cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="strict",
            check=False, timeout=120)
        if completed.returncode != 0:
            errors.append(
                f"U1c0 no-std HOF fallback failed: exit={completed.returncode} "
                f"stdout={completed.stdout!r} stderr={completed.stderr!r}")
        elif completed.stdout != "OK\n" or completed.stderr:
            errors.append(
                f"U1c0 no-std HOF fallback output drifted: "
                f"stdout={completed.stdout!r} stderr={completed.stderr!r}")
    if _sha256_file(compiler) != before:
        errors.append("pinned Ring compiler changed across U1c0 no-std check")
    return errors


def identity_checkpoint_source_errors() -> List[str]:
    paths = {
        "ast": REPO / "compiler" / "ast.ring",
        "parser": REPO / "compiler" / "parser.ring",
        "env": REPO / "compiler" / "env.ring",
        "types": REPO / "compiler" / "types.ring",
        "inventory": REPO / "compiler" / "ir_inventory.ring",
        "identity": REPO / "compiler" / "ir_identity.ring",
        "builtins": REPO / "compiler" / "builtins.ring",
        "hir": REPO / "compiler" / "hir.ring",
        "infer": REPO / "compiler" / "infer.ring",
        "infer_decl": REPO / "compiler" / "infer_decl.ring",
        "andor": REPO / "compiler" / "andor_lower.ring",
        "checker": REPO / "compiler" / "checker.ring",
        "infer_ctx": REPO / "compiler" / "infer_ctx.ring",
        "infer_helpers": REPO / "compiler" / "infer_helpers.ring",
        "zonk": REPO / "compiler" / "zonk.ring",
        "derive": REPO / "compiler" / "derive.ring",
        "dict": REPO / "compiler" / "dict_lower.ring",
        "cctx": REPO / "compiler" / "codegen_c_ctx.ring",
        "cgen": REPO / "compiler" / "codegen_c.ring",
        "cexpr": REPO / "compiler" / "codegen_c_expr.ring",
        "cli": REPO / "compiler" / "cli.ring",
        "runner": REPO / "tests" / "run_tests.py",
        "provenance_fixture": (
            REPO / "tests" / "cases" / "provenance_b_capture_identity.ring"
        ),
        "provenance_contract": REPO / "tests" / "test_provenance_b_contract.py",
    }
    sources: dict[str, str] = {}
    errors: List[str] = []
    for label, path in paths.items():
        try:
            sources[label] = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            errors.append(f"cannot read {display_path(path)}: {exc}")
    if errors:
        return errors
    errors.extend(identity_checkpoint_contract_errors(sources))
    errors.extend(identity_ledger_mutation_matrix_errors())
    errors.extend(identity_stdout_canonicalization_errors())

    mutations = (
        ("Drop DefId", "hir",
         "Drop { name: Str, def_id: Int, slot: SlotRef, site: HResourceSite,",
         "Drop { name: Str, slot: SlotRef, site: HResourceSite,"),
        ("Take exact source slot", "hir",
         "Take { source: HExpr, source_slot: SlotRef, saved_slot: SlotRef?,",
         "Take { source: HExpr, saved_slot: SlotRef?,"),
        ("HDecl exact executable", "hir",
         "Fn { name: Str, def_id: Int?, executable_ref: ExecutableRef,",
         "Fn { name: Str, def_id: Int?,"),
        ("builtin value site census", "identity",
         "pub const BUILTIN_VALUE_SITE_COUNT: Int = 10",
         "pub const BUILTIN_VALUE_SITE_COUNT: Int = 9"),
        ("builtin value fixed relation", "builtins",
         '"ptr_copy", builtin_value_site_from_tag(BUILTIN_VALUE_PTR_COPY)',
         '"ptr_copy", builtin_value_site_from_tag(BUILTIN_VALUE_DEALLOC)'),
        ("checker builtin SymbolRef relation", "checker",
         "checker_builtin_value_symbol(builtin)",
         "value_symbol_ref(ctx, 0)"),
        ("typed callee carrier", "hir", "callee_ref: CalleeRef?",
         "callee_ref: Str?"),
        ("resolver value SymbolRef census", "infer_ctx",
         "for binding in plan.bindings {\n        match binding.namespace {",
         "for binding in [] {\n        match binding.namespace {"),
        ("local callee exact module", "infer",
         "current_identity_file_key(ctx),\n                        slot_domain_lexical(), def_id",
         '"forged",\n                        slot_domain_lexical(), def_id'),
        ("assignment exact slot", "cexpr", "c_exact_value_slot(ctx, name, exact_def_id)",
         "ctx.named_values.get(name)"),
        ("exact local closure call", "cexpr",
         "ctx, c_ref_exact(slot), arg_vals",
         "let closure_result = gen_c_direct_call(ctx, name, arg_vals, dict_vals)"),
        ("capture extraction atomic event", "cexpr",
         "c_record_capture_extract(\n        ctx, edge, dest, \"env\", dest_name, index)",
         "c_record_capture_extract(\n        ctx, edge, identity, \"env\", dest_name, index)"),
        ("capture store atomic event", "cexpr",
         "c_record_capture_store(\n        ctx, edge, identity, source_name, env_name, index)",
         "c_record_capture_store(\n        ctx, edge, identity, source_name, source_name, index)"),
        ("dict receiver atomic domain guard", "cexpr",
         'domain != "name-only" && domain != "static" && domain != "computed"',
         "false"),
        ("system host call carrier", "hir",
         "system_host: SystemHostCallableRef?",
         "system_host: Str?"),
        ("dict receiver ledger domain guard", "cctx",
         'event.domain != "name-only" && event.domain != "static" &&',
         "false &&"),
        ("system host producer", "infer",
         "system_effects.get(0).unwrap(),\n"
         "        make_named_executable_ref(callee_ref_named_symbol(callee_ref))",
         "system_effects.last().unwrap(),\n"
         "        make_named_executable_ref(callee_ref_named_symbol(callee_ref))"),
        ("capture edge environment", "cctx",
         "store.dest_slot != edge.source_slot",
         "store.dest_slot == edge.source_slot"),
        ("capture store child frame", "cctx",
         "store.child_frame != edge.child_frame",
         "store.child_frame == edge.child_frame"),
        ("capture extract parent frame", "cctx",
         "extract.parent_frame != edge.parent_frame",
         "extract.parent_frame == edge.parent_frame"),
        ("frame-qualified exact/name-only slots", "cctx",
         '"${frame.len()}:${frame}:${slot}"',
         'slot'),
        ("name-only census current-frame filter", "cexpr",
         "// registered before its actual use.  c_resolve_dict_ref is the loud\n"
         "        // authority if no local/outer slot exists at that use point.\n"
         "        none => return",
         "// broken census eagerly treats a lambda-local as missing\n"
         "        none => panic(\"missing capture slot\")"),
        ("exact census current-frame filter", "cexpr",
         "// Not free in the enclosing frame: it is lambda-local or global.\n"
         "            // Exact use-time lookup remains fail-closed for a malformed local.\n"
         "            return",
         "panic(\"exact capture missing from outer frame\")"),
        ("optional evidence remains optional", "cexpr",
         "some(matched) => push_c_name_only_capture(matched, false, captures),\n"
         "        none => {}",
         "some(matched) => push_c_name_only_capture(matched, false, captures),\n"
         "        none => panic(\"missing optional evidence\")"),
        ("callee name-only tag", "cexpr",
         "HExpr::Ident { name, resolved_name, def_id: none, .. }",
         "HExpr::Ident { name, resolved_name, .. }"),
        ("DirectCallable final marker", "zonk",
         "ValueBindingKind::DirectCallable =>\n"
         "                            mark_zonk_direct_callee(ident)",
         "ValueBindingKind::DirectCallable => ident"),
        ("ExternCallable final marker", "zonk",
         "ValueBindingKind::ExternCallable =>\n"
         "                            mark_zonk_direct_callee(ident)",
         "ValueBindingKind::ExternCallable => ident"),
        ("constructor exact target", "infer_helpers",
         "exact_variant_constructor_target(ctx, def_id).is_some()",
         "false"),
        ("LocalBorrow marker clearing", "zonk",
         "..ident, dict_closure_dicts: none",
         "..ident, dict_closure_dicts: some([])"),
        ("ConstGetter direct marker", "infer_helpers",
         "dict_closure_dicts: some([]), ty: getter_ty",
         "dict_closure_dicts: none, ty: getter_ty"),
        ("dict CalleeRef transport", "dict",
         "callee_ref: callee_ref,\n                method_ref: dl_method_call_ref",
         "callee_ref: none,\n                method_ref: dl_method_call_ref"),
        ("andor CalleeRef transport", "andor",
         "resolved_dicts: resolved_dicts, callee_ref: callee_ref,",
         "resolved_dicts: resolved_dicts, callee_ref: none,"),
        ("zonk CalleeRef transport", "zonk",
         "callee_ref: callee_ref,\n                method_ref: zonk_method_call_ref",
         "callee_ref: none,\n                method_ref: zonk_method_call_ref"),
        ("direct predicate exact marker shape", "hir",
         "def_id: some(_), dict_closure_dicts: some(_), ..",
         ".."),
        ("exact callee miss panic", "cexpr",
         "none => panic(\n"
         "                    \"C codegen: exact local callee '${name}' DefId ${id} has no slot\")",
         "none => gen_c_direct_call(ctx, name, arg_vals, dict_vals)"),
        ("map helper exact final-zonk authority", "infer",
         "def_id: callee_scheme.def_id, dict_closure_dicts: none",
         "def_id: none, dict_closure_dicts: none"),
        ("lambda emitter ABI manifest", "cexpr",
         'let saved = c_push_fn(ctx, lambda_name)\n'
         '    let mut sig_parts: List<Str> = ["void* env"]',
         'let saved = c_push_fn(ctx, lambda_name)\n'
         '    let mut sig_parts: List<Str> = ["void* env", "void* junk"]'),
        ("closure-call emitter grammar", "cexpr",
         'let mut call_args: List<Str> = ["((void**)${closure_val})[1]"]',
         'let mut call_args: List<Str> = ["((void**)${closure_val})[0]"]'),
        ("dict method-load emitter grammar", "cexpr",
         'emit_c_receiver_load(\n        ctx, dict_ref, method_idx + 1, "dict")',
         'emit_c_receiver_load(\n        ctx, dict_ref, 0, "dict")'),
        ("Ord method-load emitter grammar", "cexpr",
         'emit_c_receiver_load(ctx, dict_ref, 1, "dict")',
         'emit_c_receiver_load(ctx, dict_ref, 0, "dict")'),
        ("effect method-load emitter grammar", "cexpr",
         'emit_c_receiver_load(\n            ctx, ev_ref, idx + 1, "effect")',
         'emit_c_receiver_load(\n            ctx, ev_ref, 0, "effect")'),
        ("resolved name-only canonical key", "cexpr",
         "canonical_key: resolved_key, slot: slot",
         "canonical_key: bare_key, slot: slot"),
        ("direct call name-only fallback", "cexpr",
         "fn gen_c_direct_call(mut ctx: CCtx, name: Str, arg_vals: List<Str>, dict_vals: List<Str>) -> Str {",
         "fn gen_c_direct_call(mut ctx: CCtx, name: Str, arg_vals: List<Str>, dict_vals: List<Str>) -> Str {\n"
         "    let _ = c_name_only_value(ctx, name)"),
        ("Simple dictionary missing failure", "cexpr",
         "none => panic(\n"
         "                    \"C codegen: bound dictionary '${n}' has no name-only slot\")",
         "none => resolve_c_static_dict(ctx, n)"),
        ("Direct dictionary static base", "cexpr",
         "c_resolve_dict_ref(ctx, DictRef::Static(dict))",
         "c_resolve_dict_ref(ctx, DictRef::Simple(dict))"),
        ("Direct dictionary capture census", "cexpr",
         "TraitDispatch::Direct { extra_dicts, .. }",
         "TraitDispatch::Direct { dict, extra_dicts }"),
        ("Wrapped dictionary capture census", "cexpr",
         "DictRef::Wrapped { inner_dicts, .. }",
         "DictRef::Wrapped { dict, inner_dicts, .. }"),
        ("bound method evidence tag", "infer",
         "bound_evidence = some(DictRef::Simple(",
         "bound_evidence = some(DictRef::Static("),
        ("delegated bound evidence tag", "infer_decl",
         "DictRef::Static(dict_name), tm.ty",
         "DictRef::Simple(dict_name), tm.ty"),
        ("FieldAction bound base tag", "derive",
         "base_dict: DictRef::Simple(\n"
         "                    trait_bound_param_name(param_name, trait_name))",
         "base_dict: DictRef::Static(\n"
         "                    trait_bound_param_name(param_name, trait_name))"),
        ("wildcard internal temp", "cexpr",
         "if binding == \"_\" {\n"
         "        // Wildcards need a C assignment target, not a Ring binding.  Keep the\n"
         "        // internal temp out of exact and name-only registries.\n"
         "        fresh_tmp(ctx)",
         "if binding == \"_\" {\n"
         "        c_local(ctx, \"__ring_for_wildcard\")"),
        ("pattern wildcard guard deletion", "cexpr",
         "    if name == \"_\" {\n"
         "        return fresh_tmp(ctx)\n"
         "    }\n",
         ""),
        ("pattern wildcard guard reversal", "cexpr",
         "    if name == \"_\" {\n"
         "        return fresh_tmp(ctx)\n"
         "    }\n",
         "    if name != \"_\" {\n"
         "        return fresh_tmp(ctx)\n"
         "    }\n"),
        ("synthetic Dict provenance", "cexpr",
         "is_synthetic_dict_def_id(id)",
         "is_synthetic_anf_def_id(id)"),
        ("Let Dict DefId routing", "cexpr",
         "let is_name_only_dict = c_is_name_only_dict_def_id(def_id)",
         "let is_name_only_dict = false"),
        ("exact local mut-flag isolation", "cexpr",
         "// Unmarked exact local: gen_c_call will fail loud.\n"
         "                        none => { return none }",
         "// Broken: unmarked local inherits module metadata.\n"
         "                        none => {}"),
        ("independent name-only slot map", "cctx",
         "ctx.name_only_slots.get(name)", "ctx.named_values.get(name)"),
        ("nested name-only domain restoration", "cctx",
         "ctx.name_only_slots = saved.name_only_slots",
         "ctx.name_only_slots = saved.named_values"),
        ("typed exact slot map", "cctx",
         "pub value_slots_by_def_id: Map<Int, CExactSlotRef>",
         "pub value_slots_by_def_id: Map<Int, Str>"),
        ("typed name-only slot map", "cctx",
         "pub name_only_slots: Map<Str, CNameOnlySlotRef>",
         "pub name_only_slots: Map<Str, Str>"),
        ("typed reference constructor validation", "cctx",
         "validate_c_typed_ref(CTypedRef {",
         "CTypedRef {"),
        ("typed reference empty slot guard", "cctx",
         'reference.c_name == "" || reference.load_id < 0',
         "reference.load_id < 0"),
        ("Exact domain shape guard", "cctx",
         'def_id == -1 || canonical_key == "" || producer != ""',
         "false"),
        ("keyed domain shape guard", "cctx",
         'def_id != -1 || canonical_key == "" || producer != ""',
         "false"),
        ("produced domain shape guard", "cctx",
         'def_id != -1 || canonical_key != "" || producer == ""',
         "false"),
        ("Ring event shape authority", "cctx",
         "validate_identity_event_shape(event)",
         "if false { validate_identity_event_shape(event) }"),
        ("closure-edge Fresh provenance", "cctx",
         'event.producer != "closure-edge:${event.child_frame}"',
         "false"),
        ("Python event shape authority", "runner",
         "errors.extend(identity_ledger_event_shape_errors(event))",
         "errors.extend([])"),
        ("closure call atomic event", "cexpr",
         "c_record_closure_call(\n        ctx, closure_ref, closure_val, t, arg_vals.len() + 1)",
         "c_record_closure_call(\n        ctx, c_ref_computed(closure_val, \"forged\"), closure_val, t, arg_vals.len() + 1)"),
        ("ledger relation before write", "cgen",
         "some(c_identity_ledger_text(ctx))",
         "some(\"unvalidated-ledger\")"),
        ("ledger single write", "cgen",
         'some(ledger_text) => write_file(\n            "${c_path}.identity-ledger", ledger_text)',
         'some(ledger_text) => {\n            write_file("${c_path}.identity-ledger", ledger_text)\n            write_file("${c_path}.identity-ledger", ledger_text)\n        }'),
        ("raw capture emitter bypass", "cexpr",
         "emit_c_capture_store(ctx, edge, identity, env_ref, i + 1)",
         'c_emit(ctx, "((void**)${env})[${i + 1}] = ${cv};")'),
        ("caller supplied ledger event", "cexpr",
         "emit_c_capture_extract(ctx, edge, identity, dest, i + 1)",
         "emit_c_capture_extract(ctx, edge, identity, dest, i + 1)\n"
         "                c_record_capture_extract(ctx, edge, identity, \"env\", \"forged\", i + 1)"),
        ("computed wrapper exclusion", "cexpr",
         'fwd_args.push("((void**)env)[${i + 1}]")',
         'fwd_args.push("BROKEN_SOURCE_IDENTITY_ENV")'),
        ("hidden flag value path", "cli",
         'arg == "--internal-c-identity-ledger"',
         'arg.starts_with("--internal-c-identity-ledger=")'),
        ("candidate evidence-root authority", "runner",
         "evidence_root, evidence_error = identity_checkpoint_evidence_root()\n"
         "    if evidence_error is not None:",
         "evidence_root, evidence_error = Path(tempfile.gettempdir()), None\n"
         "    if evidence_error is not None:"),
        ("candidate evidence archive", "runner",
         "create_one_shot_archive(case_root, archive_path)\n"
         "        archive_sha256 = _sha256_file(archive_path)",
         "archive_sha256 = 'not-retained'"),
        ("nested candidate inherits reviewed outer environment", "runner",
         "    environment = dict(os.environ)\n"
         "    environment.pop(IDENTITY_CANDIDATE_ENV, None)\n"
         "    environment.pop(IDENTITY_EVIDENCE_ROOT_ENV, None)",
         "    environment = dict(_controlled_environment(ring_exe, clang))"),
        ("COFF timestamp range", "runner",
         "    allowed_offsets = {4, 5, 6, 7}",
         "    allowed_offsets = {4, 5, 6, 7, 8}"),
        ("COFF AMD64 machine guard", "runner",
         "        if machine != 0x8664:",
         "        if False:"),
        ("COFF object helper routing", "runner",
         "    errors.extend(coff_object_timestamp_equality_errors(\n"
         "        \"off/on1 object\", off.object_bytes, on1.object_bytes))\n"
         "    errors.extend(coff_object_timestamp_equality_errors(\n"
         "        \"on1/on2 object\", on1.object_bytes, on2.object_bytes))",
         "    if off.object_bytes != on1.object_bytes:\n"
         "        errors.append(\"identity ledger changed off/on1 object bytes\")\n"
         "    if on1.object_bytes != on2.object_bytes:\n"
         "        errors.append(\"identity ledger changed on1/on2 object bytes\")"),
        ("candidate source fail-first", "runner",
         "errors = identity_checkpoint_source_errors()\n"
         "    if errors:\n"
         "        return errors, \"source/mutation authority failed; "
         "candidate not evaluated\"",
         "errors = identity_checkpoint_source_errors()\n"
         "    if false:\n"
         "        return errors, \"source/mutation authority failed; "
         "candidate not evaluated\""),
        ("or-pattern shared slot", "cexpr", "bind_c_root_pattern_after_success(",
         "bind_c_nested_pattern("),
        ("trait default HParam identity", "infer_decl", "def_id: some(trait_param_def_id)",
         "def_id: none"),
        ("trait default body identity", "infer_decl", "def_id: some(exact_trait_def_id)",
         "def_id: some(ctx.env.fresh_def_id())"),
        ("function registration DefId authority", "infer_decl",
         "let fn_def_id = match registration_scheme {\n"
         "        some(scheme) => scheme.def_id,\n"
         "        none => none\n"
         "    }",
         "let fn_scheme = ctx.env.lookup(name)\n"
         "    let fn_def_id = match fn_scheme { some(s) => s.def_id, none => none }"),
        ("checker move error guard", "checker",
         "if !has_errors && assembled.drop_types.len() > 0",
         "if assembled.drop_types.len() > 0"),
        ("checker lowering error guard", "checker",
         "let checked_program = if has_errors {\n"
         "        assembled\n"
         "    } else {\n"
         "        lower_dicts(lower_andor(assembled))\n"
         "    }",
         "let checked_program = lower_dicts(lower_andor(assembled))"),
        ("or-pattern canonical restore", "infer_ctx",
         "ctx.env.bind(authority.name, authority.scheme)",
         "ctx.env.bind(authority.name, candidate)"),
        ("or-pattern type compatibility", "infer_ctx",
         "authority.scheme.ty, candidate.ty",
         "authority.scheme.ty, authority.scheme.ty"),
        ("or-pattern duplicate rejection", "infer_ctx",
         "if report_duplicate_or_pattern_bindings(\n                        ctx.sink, duplicates, span) {",
         "if false {"),
        ("nested scope", "infer", "infer_scoped_block(ctx, expr, some(subst))",
         "infer_block(ctx, expr, some(subst))"),
        ("HIR crossing arm split", "hir",
         "HStmt::Let { name, def_id, init, .. } =>\n"
         "            validate_hir_local_binding(\n"
         "                name, def_id, init, seen, scope),\n"
         "        HStmt::Var { name, def_id, init, .. } =>\n"
         "            validate_hir_local_binding(\n"
         "                name, def_id, init, seen, scope)",
         "HStmt::Let { name, def_id, init, .. } |\n"
         "        HStmt::Var { name, def_id, init, .. } =>\n"
         "            validate_hir_local_binding(\n"
         "                name, def_id, init, seen, scope)"),
    )
    for label, source_name, anchor, replacement in mutations:
        if sources[source_name].count(anchor) < 1:
            errors.append(f"mutation {label}: anchor missing")
            continue
        mutated = dict(sources)
        mutated[source_name] = sources[source_name].replace(anchor, replacement, 1)
        if not identity_checkpoint_contract_errors(mutated):
            errors.append(f"mutation {label} escaped exact-slot source oracle")
    return errors


def preacceptance_source_contract_errors(
    sources: Mapping[str, str],
) -> List[str]:
    """Cheap A1 receipt-atomicity and Core-to-Flow temp authority guard."""
    errors: List[str] = []
    specs = (
        ("transaction", "infer_decl", "infer_and_commit_value_draft_group", (
            "begin_infer_mutation_journal(ctx)",
            "preflight_value_draft_group(ctx, prepared)",
            "let declarations = commit_value_draft_group(ctx, prepared)",
            "commit_infer_mutation_journal(ctx, mutation_checkpoint)",
            "rollback_infer_mutation_journal(ctx, mutation_checkpoint)",
        )),
        ("impl-transaction", "infer_decl", "infer_and_commit_impl_draft_group", (
            "begin_infer_mutation_journal(ctx)",
            "preflight_impl_draft_group(",
            "let declarations = commit_impl_draft_group(",
            "commit_infer_mutation_journal(ctx, mutation_checkpoint)",
            "rollback_infer_mutation_journal(ctx, mutation_checkpoint)",
        )),
        ("prepare", "infer_decl", "prepare_fn_draft_group", (
            "preflight_owner_batches(ctx, batches)",)),
        ("publish", "infer_ctx", "publish_owner_batches", (
            "preflight_owner_batches(ctx, batches)",
            "publish_effect_fact_batches(ctx.env, facts)")),
        ("projection", "infer_ctx", "project_owner_batch_receipts", (
            "headers, pending.target",
            "pending.receipt.source_to_actual.get(source)",
            "for projection in finalized",
            "batch.pending_projections = []")),
        ("call", "infer", "infer_call", (
            "false, callee_receipts", "if callee_receipts.len() != 1",
            "let receipt = callee_receipt.unwrap_or_else",
            "metadata.live_scheme, receipt, s, span")),
        ("assoc", "infer", "for_protocol_assoc_type", (
            "instantiate_assoc_type_from_callable_receipt(\n"
            "        receipt, localized_assoc, subst)",)),
        ("admin-site", "flow", "admin_site", (
            'path.push("$flow")', "path.push(label)", "path.push(ordinal.to_str())",
            "make_path_ref(executable_path_owner(ctx.owner), path, role)")),
        ("admin-slot", "flow", "new_admin_slot", (
            "admin_site(ctx, label, ctx.slots.len(), role_tag)",
            "make_synthetic_slot_ref(site)",
            "reference, ctx.owner, kind, site",
            "scope_slot_count(ctx, scope)")),
        ("manifest", "inventory", "make_binder_manifest", (
            "if slot_ref_same(left.slot, right.slot)",)),
    )
    bodies: Dict[str, str] = {}
    for key, source_name, function_name, tokens in specs:
        body, error = extract_ring_function_body(sources[source_name], function_name)
        if error:
            errors.append(error)
            continue
        assert body is not None
        bodies[key] = body
        if any(token not in body for token in tokens):
            errors.append(f"preacceptance {key} contract drifted")
    transaction = bodies.get("transaction", "")
    if not (
        transaction.find("preflight_value_draft_group(ctx, prepared)")
        < transaction.find("let declarations = commit_value_draft_group(ctx, prepared)")
        < transaction.find("commit_infer_mutation_journal(ctx, mutation_checkpoint)")
    ):
        errors.append("A1 group publish order drifted")
    impl_transaction = bodies.get("impl-transaction", "")
    if not (
        impl_transaction.find("preflight_impl_draft_group(")
        < impl_transaction.find("let declarations = commit_impl_draft_group(")
        < impl_transaction.find(
            "commit_infer_mutation_journal(ctx, mutation_checkpoint)")
    ):
        errors.append("A1 impl group publish order drifted")
    publish = bodies.get("publish", "")
    if publish.find("preflight_owner_batches(ctx, batches)") > publish.find(
            "publish_effect_fact_batches(ctx.env, facts)"):
        errors.append("A1 owner facts publish before group preflight")
    if (
        "pub struct CallableInstantiationReceipt {\n"
        "    ty: Type,\n    source_to_actual: Map<Int, Type>," not in
        sources["infer_ctx"]
        or "source: PendingEvidenceSource,\n"
        "    receipt: CallableInstantiationReceipt,\n"
        "    fn_bounds: List<FnBoundsEntry>," not in sources["infer_ctx"]
    ):
        errors.append("A1 unique CallableInstantiationReceipt carrier drifted")
    core = mask_ring_strings_and_comments(sources["core"])
    for kind in ("pre_anf", "scope_result", "control_result", "assign_temp"):
        if f"binder_kind_{kind}()" in core:
            errors.append(f"Core prebuilt Flow administrative temp {kind}")
    return errors

OWNERSHIP_CUTOVER_PATHS = {
    "checker": REPO / "compiler" / "checker.ring",
    "cli": REPO / "compiler" / "cli.ring",
    "project": REPO / "compiler" / "compiler_mod.ring",
    "pipeline": REPO / "compiler" / "ownership_pipeline.ring",
    "hir_exact": REPO / "compiler" / "hir_exact.ring",
    "infer": REPO / "compiler" / "infer.ring",
    "infer_decl": REPO / "compiler" / "infer_decl.ring",
    "infer_ctx": REPO / "compiler" / "infer_ctx.ring",
    "core": REPO / "compiler" / "core_from_hir.ring",
    "flow": REPO / "compiler" / "flow_lower.ring",
    "inventory": REPO / "compiler" / "ir_inventory.ring",
}


def ownership_cutover_source_errors() -> List[str]:
    sources: dict[str, str] = {}
    errors: List[str] = []
    for label, path in OWNERSHIP_CUTOVER_PATHS.items():
        try:
            sources[label] = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            errors.append(f"cannot read {display_path(path)}: {exc}")
    if errors:
        return errors

    for label in ("cli", "project"):
        masked = mask_ring_strings_and_comments(sources[label])
        if re.search(r"(?m)^\s*use\s+perceus\b", masked):
            errors.append(f"{label}: direct Perceus import survived Core cutover")
        if re.search(r"\bperceus_transform\s*\(", masked):
            errors.append(f"{label}: direct Perceus call survived Core cutover")

    error_result, error_result_error = extract_ring_function_body(
        sources["checker"], "failed_check_result")
    if error_result_error:
        errors.append(error_result_error)
    elif not all(token in error_result for token in (
            "core_facts: none", "legacy_facts: none")):
        errors.append("checker: diagnostic result published frozen facts")

    for function_name in ("check", "check_module"):
        body, body_error = extract_ring_function_body(
            sources["checker"], function_name)
        if body_error:
            errors.append(body_error)
            continue
        required = (
            "let frozen = if has_errors { none } else { some(",
            "freeze_core_and_legacy_facts(",
            "ctx.core_module_key, ctx.core_module_order,",
            "checked_program, ctx.env,",
            "core_facts: frozen.map(",
            "frozen_core_and_legacy_core(value)",
            "legacy_facts: frozen.map(",
            "frozen_core_and_legacy_legacy(value)",
        )
        for token in required:
            if token not in body:
                errors.append(
                    f"checker.{function_name}: cutover relation misses {token!r}")
        for retired in (
                "ctx.core_recorder", "ctx.core_type_sources",
                "ctx.core_handled_evidence_type_sources"):
            if retired in body:
                errors.append(
                    f"checker.{function_name}: retired freeze input {retired!r} survived")

    def require_order(
        label: str, body: str, tokens: Tuple[str, ...],
    ) -> None:
        positions = [body.find(token) for token in tokens]
        if any(position < 0 for position in positions):
            errors.append(f"{label}: ownership stage census is incomplete")
        elif positions != sorted(positions) or len(set(positions)) != len(positions):
            errors.append(f"{label}: ownership stage order drifted")

    pipeline, pipeline_error = extract_ring_function_body(
        sources["pipeline"], "run_ownership_pipeline")
    if pipeline_error:
        errors.append(pipeline_error)
    else:
        require_order("ownership_pipeline.run_ownership_pipeline", pipeline, (
            "lower_core_to_flow(validated_core)",
            "verify_and_plan_resource_program(flow)",
            "if !planning_outcome_is_verified(planning)",
            "planning_outcome_verified(planning)",
        ))
        for token in (
                "OwnershipPipelineFailedValue(",
                "findings: findings, step_map: step_map",
                "OwnershipPipelineVerifiedValue("):
            if token not in pipeline:
                errors.append(
                    f"ownership pipeline: outcome closure misses {token!r}")

    diagnostic_adapter, diagnostic_adapter_error = extract_ring_function_body(
        sources["pipeline"], "ownership_pipeline_failure_diagnostics")
    if diagnostic_adapter_error:
        errors.append(diagnostic_adapter_error)
    else:
        for token in (
                "failed_ownership_program_core_node_for_finding(",
                "core_diagnostic_projection_origin_location(",
                "core_diagnostic_projection_slot_display_label(",
                "E0801", "use of moved value:"):
            if token not in diagnostic_adapter:
                errors.append(
                    f"ownership diagnostics: exact adapter misses {token!r}")

    single_report, single_report_error = extract_ring_function_body(
        sources["cli"], "report_single_ownership_failure")
    if single_report_error:
        errors.append(single_report_error)
    elif not all(token in single_report for token in (
            "ownership_pipeline_failure_diagnostics(",
            "diagnostic.span.file != file_path", "sink.report(diagnostic)",
            "failed single-file plan emitted no error")):
        errors.append("cli: single ownership diagnostic route drifted")

    single_materialize, single_materialize_error = extract_ring_function_body(
        sources["cli"], "materialize_single_verified_ownership")
    if single_materialize_error:
        errors.append(single_materialize_error)
    else:
        require_order("cli.materialize_single_verified_ownership",
                      single_materialize, (
            "assemble_legacy_projection(",
            "verified_ownership_program_flow(verified)",
            "materialize_verified_hir(",
        ))

    project_run, project_run_error = extract_ring_function_body(
        sources["project"], "run_project_ownership")
    if project_run_error:
        errors.append(project_run_error)
    else:
        require_order("compiler_mod.run_project_ownership", project_run, (
            "assemble_project_core(core_facts)",
            "run_ownership_pipeline(",
        ))

    project_report, project_report_error = extract_ring_function_body(
        sources["project"], "report_project_ownership_failure")
    if project_report_error:
        errors.append(project_report_error)
    elif not all(token in project_report for token in (
            "ownership_pipeline_failure_diagnostics(",
            "diagnostic.span.file != module.file_path",
            "for key in phases.graph.topo_order", "sink.report(diagnostic)",
            "failed plan emitted no error")):
        errors.append("compiler_mod: project ownership diagnostic route drifted")

    project, project_error = extract_ring_function_body(
        sources["project"], "materialize_verified_project_ownership")
    if project_error:
        errors.append(project_error)
    else:
        require_order("compiler_mod.materialize_verified_project_ownership",
                      project, (
            "for key in phases.graph.topo_order",
            "assemble_legacy_projection(",
            "verified_ownership_program_flow(verified)",
            "materialize_verified_project_hir(",
        ))
        for token in (
                "make_verified_project_hir_shell(",
                "key, phases.module_hirs.get(key)",
                "materialized_project_hir_module_key(value)",
                "result.insert(key, materialized_project_hir_program(value))",
                "result.len() != phases.graph.topo_order.len()"):
            if token not in project:
                errors.append(
                    f"compiler_mod: project shell partition misses {token!r}")

    for function_name in (
            "compile_project", "compile_project_c", "verify_project_rc"):
        body, body_error = extract_ring_function_body(
            sources["project"], function_name)
        if body_error:
            errors.append(body_error)
        elif not all(token in body for token in (
                "run_project_ownership(phases)",
                "ownership_pipeline_outcome_is_verified(ownership)",
                "report_project_ownership_failure(",
                "materialize_verified_project_ownership(")):
            errors.append(
                f"compiler_mod.{function_name}: project ownership outcome path drifted")
    if "--rc-mutate has no typed ownership-pipeline mutation entry" not in (
            sources["cli"] + sources["project"]):
        errors.append("ownership cutover: unsupported mutation did not fail loud")

    default_fields, default_fields_error = _f0_struct_fields(
        sources["hir_exact"], "HDefaultSpecializationPlan")
    if default_fields_error:
        errors.append(default_fields_error)
    elif default_fields is not None and [name for _, name in default_fields] != [
            "owner", "generated_method", "generated_executable",
            "source_method", "default_executable", "parameter_types",
            "parameter_mutabilities", "binders", "result_type", "effects",
            "forward_call"]:
        errors.append("default specialization exact carrier drifted")
    if "trait_method.param_mutabilities, binders" not in sources["infer_decl"]:
        errors.append("default specialization lost registered mutabilities")
    if "h_default_specialization_parameter_mutabilities(plan)" not in (
            sources["core"]):
        errors.append("Core default elaboration guessed parameter mutability")

    guard_errors = preacceptance_source_contract_errors(sources)
    errors.extend(guard_errors)
    if not guard_errors:
        mutations = (
            ("group-preflight", "infer_decl", "infer_and_commit_value_draft_group",
             "preflight_value_draft_group(ctx, prepared)", "{}"),
            ("publish-preflight", "infer_ctx", "publish_owner_batches",
             "preflight_owner_batches(ctx, batches)", "{}"),
            ("failure-rollback", "infer_decl", "infer_and_commit_value_draft_group",
             "rollback_infer_mutation_journal(ctx, mutation_checkpoint)", "{}"),
            ("impl-preflight", "infer_decl", "infer_and_commit_impl_draft_group",
             "preflight_impl_draft_group(", "discard_impl_preflight("),
            ("impl-commit-journal", "infer_decl", "infer_and_commit_impl_draft_group",
             "commit_infer_mutation_journal(ctx, mutation_checkpoint)", "{}"),
            ("impl-failure-rollback", "infer_decl", "infer_and_commit_impl_draft_group",
             "rollback_infer_mutation_journal(ctx, mutation_checkpoint)", "{}"),
            ("receipt-missing", "infer", "infer_call",
             "false, callee_receipts", "false, []"),
            ("receipt-delete", "infer_ctx", None,
             "runtime_owner: ExecutableRef,\n"
             "    source: PendingEvidenceSource,\n"
             "    receipt: CallableInstantiationReceipt,",
             "runtime_owner: ExecutableRef,\n"
             "    source: PendingEvidenceSource,"),
            ("receipt-swap", "infer_ctx", "project_owner_batch_receipts",
             "headers, pending.target", "headers, headers.first().unwrap().executable"),
            ("consumer-rebuild", "infer", "for_protocol_assoc_type",
             "instantiate_assoc_type_from_callable_receipt(\n"
             "        receipt, localized_assoc, subst)", "localized_assoc"),
            ("Core-prebuild", "core", "body_anchor",
             "let mut path = executable_prefix(value)",
             "let _ = binder_kind_pre_anf()\n    let mut path = executable_prefix(value)"),
            ("scope-ordinal", "flow", "new_admin_slot",
             "admin_site(ctx, label, ctx.slots.len(), role_tag)",
             "admin_site(ctx, label, scope_slot_count(ctx, scope), role_tag)"),
            ("duplicate-PathRef", "flow", "new_admin_slot",
             "admin_site(ctx, label, ctx.slots.len(), role_tag)",
             "admin_site(ctx, label, 0, role_tag)"),
        )
        for label, source_name, function_name, anchor, replacement in mutations:
            mutated = dict(sources)
            if function_name is None:
                if sources[source_name].count(anchor) != 1:
                    errors.append(f"preacceptance mutation anchor drifted: {label}")
                    continue
                mutated[source_name] = sources[source_name].replace(
                    anchor, replacement, 1)
            else:
                value, mutation_error = _f0_mutate_function_once(
                    sources[source_name], function_name, anchor, replacement)
                if mutation_error:
                    errors.append(f"preacceptance mutation {label}: {mutation_error}")
                    continue
                assert value is not None
                mutated[source_name] = value
            if not preacceptance_source_contract_errors(mutated):
                errors.append(f"preacceptance mutation escaped: {label}")
    return errors


def identity_checkpoint_candidate_identity(
) -> Tuple[Optional[str], Optional[str], Optional[str]]:
    """Resolve and hash the explicitly selected I-prime candidate compiler."""
    raw = os.environ.get(IDENTITY_CANDIDATE_ENV)
    if raw is None:
        return None, None, None
    if not raw:
        return None, None, f"{IDENTITY_CANDIDATE_ENV} is empty"
    candidate = Path(raw)
    if not candidate.is_absolute():
        return None, None, f"{IDENTITY_CANDIDATE_ENV} must be an absolute path"
    try:
        resolved = candidate.resolve(strict=True)
        before = resolved.stat()
        if not stat.S_ISREG(before.st_mode):
            return None, None, (
                f"{IDENTITY_CANDIDATE_ENV} is not a regular file: {resolved}")
        digest = _sha256_file(resolved)
        after = resolved.stat()
    except OSError as exc:
        return None, None, (
            f"cannot resolve/hash {IDENTITY_CANDIDATE_ENV}: {exc}")
    if (
        before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
    ):
        return None, None, (
            f"{IDENTITY_CANDIDATE_ENV} changed while hashing: {resolved}")
    return str(resolved), digest, None


def identity_checkpoint_evidence_root(
) -> Tuple[Optional[Path], Optional[str]]:
    raw = os.environ.get(IDENTITY_EVIDENCE_ROOT_ENV)
    if raw is None:
        return None, f"{IDENTITY_EVIDENCE_ROOT_ENV} is required with candidate"
    if not raw:
        return None, f"{IDENTITY_EVIDENCE_ROOT_ENV} is empty"
    candidate = Path(raw)
    if not candidate.is_absolute():
        return None, f"{IDENTITY_EVIDENCE_ROOT_ENV} must be an absolute path"
    try:
        if candidate.is_symlink():
            return None, f"{IDENTITY_EVIDENCE_ROOT_ENV} must not be a symlink"
        resolved = candidate.resolve(strict=True)
        if candidate != resolved:
            return None, (
                f"{IDENTITY_EVIDENCE_ROOT_ENV} must be the exact canonical path")
        mode = resolved.stat().st_mode
        if not stat.S_ISDIR(mode):
            return None, f"{IDENTITY_EVIDENCE_ROOT_ENV} is not a directory"
        temp_root = Path(tempfile.gettempdir()).resolve(strict=True)
        if resolved == temp_root or temp_root in resolved.parents:
            return None, (
                f"{IDENTITY_EVIDENCE_ROOT_ENV} must be outside TemporaryDirectory")
        inventory = sorted(path.name for path in resolved.iterdir())
    except OSError as exc:
        return None, f"cannot validate {IDENTITY_EVIDENCE_ROOT_ENV}: {exc}"
    if inventory:
        return None, (
            f"{IDENTITY_EVIDENCE_ROOT_ENV} must be initially empty; "
            f"found {inventory}")
    return resolved, None


def identity_checkpoint_errors() -> Tuple[List[str], str]:
    errors = identity_checkpoint_source_errors()
    if errors:
        return errors, "source/mutation authority failed; candidate not evaluated"
    candidate, digest, candidate_error = identity_checkpoint_candidate_identity()
    if candidate_error is not None:
        errors.append(candidate_error)
        return errors, f"{IDENTITY_CANDIDATE_ENV}=invalid"
    if candidate is None:
        return errors, f"{IDENTITY_CANDIDATE_ENV}=unset; source/mutation only"
    assert digest is not None
    evidence_root, evidence_error = identity_checkpoint_evidence_root()
    if evidence_error is not None:
        errors.append(evidence_error)
        return errors, (
            f"candidate={candidate}; sha256={digest}; "
            f"{IDENTITY_EVIDENCE_ROOT_ENV}=invalid")
    assert evidence_root is not None
    evidence_log: List[str] = []
    errors.extend(default_body_identity_generated_c_errors(
        candidate, evidence_root, evidence_log))
    post_candidate, post_digest, post_error = (
        identity_checkpoint_candidate_identity())
    if post_error is not None:
        errors.append(
            f"candidate identity unavailable after generated-C gate: {post_error}")
    elif post_candidate != candidate or post_digest != digest:
        errors.append("candidate executable identity changed during generated-C gate")
    detail = (
        f"candidate={candidate}; sha256={digest}; "
        f"evidence_root={evidence_root}; evidence=[{' | '.join(evidence_log)}]")
    return errors, detail


def run_structural(ring_exe: str, collector: ResultCollector, *,
                   name_filter: Optional[str] = None) -> None:
    """Run generated-C source-map and extern-handle ownership oracles."""
    suite = "structural"
    integrity_errors = structural_fixture_integrity_errors()
    if integrity_errors:
        for index, error in enumerate(integrity_errors, 1):
            collector.add(TestResult(
                TestResult.FAIL, suite, f"fixture validation {index}", error))
        return

    # This permanent gate covers cheap source structure and parse/typecheck
    # only.  Candidate behavior requires an external source-built compiler
    # packet running the targeted project fixtures.
    provider_identity_label = "compiler.impl_provider_identity_u1c1_source_contract"
    if matches_filter(provider_identity_label, name_filter):
        provider_identity_errors = impl_provider_u1c1_source_errors()
        detail = (
            f"isolated_mutations={F2_IMPL_PROVIDER_MUTATION_COUNT}; "
            "provider_kinds=4; candidate_behavior=not_evaluated; "
            "behavior_gate=aggregate_source_built_packet")
        collector.add(TestResult(
            TestResult.PASS if not provider_identity_errors else TestResult.FAIL,
            suite, provider_identity_label,
            "; ".join([detail, *provider_identity_errors])))

    provider_carrier_label = "compiler.impl_provider_carrier_u1c2_source_contract"
    if matches_filter(provider_carrier_label, name_filter):
        provider_carrier_errors = impl_provider_u1c2_source_errors()
        detail = (
            f"isolated_mutations={F2_IMPL_PROVIDER_CARRIER_MUTATION_COUNT}; "
            f"scope_guards={F2_IMPL_PROVIDER_CARRIER_SCOPE_COUNT}; "
            "candidate_behavior=not_evaluated; "
            "behavior_gate=aggregate_source_built_packet")
        collector.add(TestResult(
            TestResult.PASS if not provider_carrier_errors else TestResult.FAIL,
            suite, provider_carrier_label,
            "; ".join([detail, *provider_carrier_errors])))

    derived_carrier_label = "compiler.derived_impl_identity_u1c4_source_contract"
    if matches_filter(derived_carrier_label, name_filter):
        derived_carrier_errors = derived_impl_carrier_u1c4_source_errors()
        if not derived_carrier_errors:
            derived_carrier_errors.extend(
                derived_impl_carrier_u1c4_fixture_errors(ring_exe))
        detail = (
            f"isolated_mutations={F2_DERIVED_IMPL_CARRIER_MUTATION_COUNT}; "
            "builtin_option_owners=3; proper_negatives=1; "
            "positive_runtime=aggregate_source_built_packet")
        collector.add(TestResult(
            TestResult.PASS if not derived_carrier_errors else TestResult.FAIL,
            suite, derived_carrier_label,
            "; ".join([detail, *derived_carrier_errors])))

    delegate_plan_label = "compiler.delegate_provider_plan_u1c3_source_contract"
    if matches_filter(delegate_plan_label, name_filter):
        delegate_plan_errors = delegate_provider_plan_u1c3_source_errors()
        if not delegate_plan_errors:
            delegate_plan_errors.extend(
                delegate_provider_plan_u1c3_fixture_errors(ring_exe))
        detail = (
            f"isolated_mutations={F2_DELEGATE_PROVIDER_PLAN_MUTATION_COUNT}; "
            "proper_fixtures=5; candidate_behavior=deferred_to_aggregate")
        collector.add(TestResult(
            TestResult.PASS if not delegate_plan_errors else TestResult.FAIL,
            suite, delegate_plan_label,
            "; ".join([detail, *delegate_plan_errors])))

    trait_identity_label = "compiler.trait_method_identity_u1c_source_contract"
    if matches_filter(trait_identity_label, name_filter):
        trait_identity_errors = trait_method_identity_u1c_source_errors()
        if not trait_identity_errors:
            trait_identity_errors.extend(
                trait_method_identity_u1c_fixture_errors(ring_exe))
        detail = (
            f"isolated_mutations="
            f"{F2_TRAIT_METHOD_IDENTITY_MUTATION_COUNT}; "
            "source_producer=resolver+builtin; proper_parser_cases=2; "
            "candidate_behavior=not_evaluated; "
            "behavior_gate=external_source_built_aggregate_packet")
        collector.add(TestResult(
            TestResult.PASS if not trait_identity_errors else TestResult.FAIL,
            suite, trait_identity_label,
            "; ".join([detail, *trait_identity_errors])))

    impl_predicate_label = "compiler.impl_predicate_u1c0_source_contract"
    if matches_filter(impl_predicate_label, name_filter):
        impl_predicate_errors = impl_predicate_u1c0_source_errors()
        if not impl_predicate_errors:
            impl_predicate_errors.extend(
                impl_predicate_u1c0_source_check_errors(ring_exe))
        if not impl_predicate_errors:
            impl_predicate_errors.extend(
                impl_predicate_u1c0_no_std_errors(ring_exe))
        detail = (
            f"source_contract_mutations="
            f"{F2_U1C0_SOURCE_CONTRACT_MUTATION_COUNT}; "
            f"impl_export_closure_mutations="
            f"{F2_IMPL_EXPORT_CLOSURE_MUTATION_COUNT}; "
            "pinned_source_checks=5; no_std_behavior_checks=1; "
            "candidate_behavior=not_evaluated; "
            "behavior_gate=external_source_built_candidate_packet")
        collector.add(TestResult(
            TestResult.PASS if not impl_predicate_errors else TestResult.FAIL,
            suite, impl_predicate_label,
            "; ".join([detail, *impl_predicate_errors])))

    nominal_field_label = "compiler.nominal_field_identity_u1b_source_contract"
    if matches_filter(nominal_field_label, name_filter):
        nominal_field_errors = nominal_field_u1b_source_errors()
        if not nominal_field_errors:
            nominal_field_errors.extend(
                nominal_field_u1b_source_check_errors(ring_exe))
        detail = (
            f"source_contract_mutations="
            f"{F2_U1B_SOURCE_CONTRACT_MUTATION_COUNT}; "
            "pinned_source_checks=2; actual_fixtures=2; "
            "candidate_behavior=not_evaluated; "
            "behavior_gate=external_source_built_candidate_packet")
        collector.add(TestResult(
            TestResult.PASS if not nominal_field_errors else TestResult.FAIL,
            suite, nominal_field_label,
            "; ".join([detail, *nominal_field_errors])))

    resolver_identity_label = "compiler.resolver_identity_u1a_source_contract"
    if matches_filter(resolver_identity_label, name_filter):
        resolver_identity_errors = resolver_identity_u1a_source_errors()
        if not resolver_identity_errors:
            resolver_identity_errors.extend(
                resolver_identity_u1a_source_check_errors(ring_exe))
        detail = (
            f"source_contract_mutations="
            f"{F2_U1A_SOURCE_CONTRACT_MUTATION_COUNT}; "
            f"scope_guards={F2_U1A_SCOPE_GUARD_COUNT}; "
            "pinned_source_checks=2; candidate_behavior=not_evaluated; "
            "behavior_gate=external_source_built_candidate_packet")
        collector.add(TestResult(
            TestResult.PASS if not resolver_identity_errors else TestResult.FAIL,
            suite, resolver_identity_label,
            "; ".join([detail, *resolver_identity_errors])))

    inventory_label = "compiler.ir_inventory_f1"
    if matches_filter(inventory_label, name_filter):
        inventory_errors = ir_inventory_f1_source_errors()
        if not inventory_errors:
            inventory_errors.extend(ir_inventory_f1_compile_errors(ring_exe))
        detail = (
            f"executable_kinds={F1_EXECUTABLE_KIND_COUNT}; "
            f"binder_kinds={F1_BINDER_KIND_COUNT}; "
            f"semantic_mutations={F1_SEMANTIC_MUTATION_COUNT}; "
            f"scope_guards={F1_SCOPE_GUARD_COUNT}; pinned_ring_checks=2")
        collector.add(TestResult(
            TestResult.PASS if not inventory_errors else TestResult.FAIL,
            suite, inventory_label,
            "; ".join([detail, *inventory_errors])))

    core_c0_label = "compiler.core_hir_c0_schema_construction"
    if matches_filter(core_c0_label, name_filter):
        core_c0_errors = core_hir_c0_source_errors()
        if not core_c0_errors:
            core_c0_errors.extend(core_hir_c0_compile_errors(ring_exe))
        detail = (
            f"source_mutations={CORE_HIR_C0_MUTATION_COUNT}; "
            f"scope_guards={CORE_HIR_C0_SCOPE_GUARD_COUNT}; "
            "pinned_source_checks=2; pipeline_consumers=1; "
            "contract_only_builtin_shadow=true; body_anchor_closure=true")
        collector.add(TestResult(
            TestResult.PASS if not core_c0_errors else TestResult.FAIL,
            suite, core_c0_label,
            "; ".join([detail, *core_c0_errors])))

    builtin_method_label = "compiler.builtin_method_intrinsic_vertical"
    if matches_filter(builtin_method_label, name_filter):
        builtin_method_errors = builtin_method_intrinsic_source_errors()
        detail = (
            "producer=registered_impl_payload; "
            "consumer=typed_hir+core_contract+flow_target+c_abi; "
            f"intrinsic_sites={len(B201_BUILTIN_METHODS)}; "
            f"source_mutations={B201_BUILTIN_METHOD_MUTATION_COUNT}; "
            "single_canary=builtin_intrinsic_identity; "
            "project_canary=builtin_intrinsic_identity_project; "
            "old_method_name_table=retired; impl_member_extern=hard_reject")
        collector.add(TestResult(
            TestResult.PASS if not builtin_method_errors else TestResult.FAIL,
            suite, builtin_method_label,
            "; ".join([detail, *builtin_method_errors])))

    impl_extern_label = "compiler.impl_extern_local_recovery"
    if matches_filter(impl_extern_label, name_filter):
        recovery_errors = builtin_impl_extern_recovery_errors(ring_exe)
        collector.add(TestResult(
            TestResult.PASS if not recovery_errors else TestResult.FAIL,
            suite, impl_extern_label,
            "; ".join([
                "hard_reject=E0103; local_recovery=next_impl_member; "
                "formats=human+llm; cases=inherent+trait",
                *recovery_errors])))

    resource_label = "compiler.resource_model_f0"
    if matches_filter(resource_label, name_filter):
        resource_errors = resource_model_f0_source_errors()
        if not resource_errors:
            resource_errors.extend(resource_model_f0_compile_errors(ring_exe))
        detail = (
            f"semantic_mutations={F0_SEMANTIC_MUTATION_COUNT}; "
            f"scope_guards={F0_SCOPE_GUARD_COUNT}; pinned_ring_checks=2")
        collector.add(TestResult(
            TestResult.PASS if not resource_errors else TestResult.FAIL,
            suite, resource_label,
            "; ".join([detail, *resource_errors])))

    ownership_cutover_label = "compiler.core_ownership_cutover"
    if matches_filter(ownership_cutover_label, name_filter):
        ownership_cutover_errors = ownership_cutover_source_errors()
        collector.add(TestResult(
            TestResult.PASS if not ownership_cutover_errors else TestResult.FAIL,
            suite, ownership_cutover_label,
            "; ".join([
                "single_project_shared_pipeline=true; "
                "legacy_projection_bound_to_verified_flow=true; "
                "direct_perceus_authority=retired",
                *ownership_cutover_errors])))

    identity_label = "compiler.identity_checkpoint"
    if matches_filter(identity_label, name_filter):
        identity_errors, identity_detail = identity_checkpoint_errors()
        detail_parts = [identity_detail, *identity_errors]
        collector.add(TestResult(
            TestResult.PASS if not identity_errors else TestResult.FAIL,
            suite, identity_label, "; ".join(detail_parts)))

    jobs = []
    for case_name, entry, fixtures in C_LINE_BUILD_CASES:
        feature_id = "backend.c_line_directives"
        label = f"{feature_id}/{case_name}"
        if (
            matches_filter(label, name_filter)
            or any(matches_filter(path, name_filter) for path in fixtures)
        ):
            jobs.append((label, "line", entry, fixtures))
    feature_id = "backend.extern_handle_rc_structural"
    if (
        matches_filter(feature_id, name_filter)
        or matches_filter(EXTERN_RC_FIXTURE, name_filter)
    ):
        jobs.append((feature_id, "extern", EXTERN_RC_FIXTURE, (EXTERN_RC_FIXTURE,)))
    with tempfile.TemporaryDirectory(prefix="ring_structural_") as tmpdir:
        temp_root = Path(tmpdir)
        for label, kind, entry, fixtures in jobs:
            if kind == "line":
                errors = run_c_line_oracle(
                    ring_exe, temp_root, entry, fixtures, label)
            else:
                errors = run_extern_rc_oracle(ring_exe, temp_root, label)
            if errors:
                collector.add(TestResult(
                    TestResult.FAIL, suite, label, "; ".join(errors)))
            else:
                collector.add(TestResult(TestResult.PASS, suite, label))


# ---------------------------------------------------------------------------
# Parity evidence matrix suite
# ---------------------------------------------------------------------------

PARITY_STATUSES = {"covered", "known-gap", "manual-evidence"}
PARITY_LANES = {
    "e2e-c", "golden-c", "native-c", "module-c",
    "check", "self-compile-c", "c-structural", "manual-source",
}
POSITIVE_PARITY_LANES = PARITY_LANES - {
    "check", "self-compile-c", "c-structural", "manual-source",
}
PARITY_GAP_TABLES = {
    "shared-positive": SHARED_POSITIVE_GAPS,
    "check-only": CHECK_ONLY_GAPS,
}


def repo_relative(path: Path) -> str:
    """Return a normalized repo-relative path."""
    return normalized_repo_path(path)


def parity_lane_members() -> dict[str, set[str]]:
    """Collect the exact evidence paths owned by each executable runner lane."""
    e2e_paths = discover_positive_cases(CASES_DIR)
    check_paths = discover_negative_cases(CASES_DIR)
    for subdir_name in EXTRA_NEG_DIRS:
        e2e_paths.extend(discover_positive_cases(CASES_DIR / subdir_name))
        check_paths.extend(discover_negative_cases(CASES_DIR / subdir_name))

    golden_paths = discover_positive_cases(GOLDEN_CASES_DIR)
    native_paths = discover_positive_cases(NATIVE_ONLY_DIR)
    module_paths = discover_module_positive(MODULES_DIR)
    module_check_paths = discover_module_negative(MODULES_DIR)

    e2e = {repo_relative(path) for path in e2e_paths}
    golden = {repo_relative(path) for path in golden_paths}
    native = {repo_relative(path) for path in native_paths}
    modules = {repo_relative(path) for path in module_paths}
    checks = {repo_relative(path) for path in check_paths + module_check_paths}
    structural = structural_fixture_paths()

    return {
        "e2e-c": e2e,
        "golden-c": golden,
        "native-c": native,
        "module-c": modules,
        "check": checks,
        "self-compile-c": {"compiler/main.ring"},
        "c-structural": structural,
    }


def display_path(path: Path) -> str:
    """Use repo-relative paths when possible, absolute paths for temp probes."""
    try:
        return repo_relative(path)
    except ValueError:
        return path.resolve().as_posix()


def companion_integrity_errors(
    cases_dir: Path = CASES_DIR,
    native_dir: Path = NATIVE_ONLY_DIR,
) -> List[str]:
    """Reject orphan companions and EXPECT_PANIC outside native_only."""
    errors: List[str] = []
    for companion in cases_dir.rglob("*"):
        if not companion.is_file() or companion.suffix not in {".expected", ".error"}:
            continue
        ring_file = companion.with_suffix(".ring")
        if not ring_file.is_file():
            errors.append(
                f"orphan companion without same-stem .ring: "
                f"{display_path(companion)}"
            )
        if companion.suffix != ".expected":
            continue
        try:
            expected_raw = companion.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            errors.append(f"cannot read {display_path(companion)}: {exc}")
            continue
        if (
            is_expect_panic(expected_raw)
            and companion.resolve().parent != native_dir.resolve()
        ):
            errors.append(
                f"EXPECT_PANIC outside native_only: {display_path(companion)}"
            )
    return errors


def mask_ring_strings_and_comments(source: str) -> str:
    """Blank strings and // comments while preserving offsets and newlines."""
    masked: List[str] = []
    state = "code"
    index = 0
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""

        if state == "code":
            if char == "/" and next_char == "/":
                masked.extend([" ", " "])
                index += 2
                state = "comment"
                continue
            if char == '"':
                masked.append(" ")
                index += 1
                state = "string"
                continue
            masked.append(char)
            index += 1
            continue

        if state == "comment":
            if char == "\n":
                masked.append("\n")
                state = "code"
            else:
                masked.append(" ")
            index += 1
            continue

        # String state.  Escaped quotes and escaped backslashes remain inside
        # the string; newlines are preserved so diagnostics keep line numbers.
        if char == "\\" and next_char:
            masked.append(" ")
            masked.append("\n" if next_char == "\n" else " ")
            index += 2
        elif char == '"':
            masked.append(" ")
            index += 1
            state = "code"
        else:
            masked.append("\n" if char == "\n" else " ")
            index += 1

    return "".join(masked)


def extract_enum_variants(source_path: Path, enum_name: str) -> set[str]:
    """Extract top-level variants from a Ring enum declaration.

    The parser is deliberately small but brace-aware: commas inside struct
    fields, tuples, lists, or generic arguments do not split variants.
    """
    source = mask_ring_strings_and_comments(
        source_path.read_text(encoding="utf-8"))
    match = re.search(
        rf"\bpub\s+enum\s+{re.escape(enum_name)}\s*\{{", source)
    if not match:
        raise ValueError(
            f"enum {enum_name} not found in {display_path(source_path)}")

    open_index = match.end() - 1
    outer_depth = 0
    close_index = None
    for index in range(open_index, len(source)):
        char = source[index]
        if char == "{":
            outer_depth += 1
        elif char == "}":
            outer_depth -= 1
            if outer_depth == 0:
                close_index = index
                break
    if close_index is None:
        raise ValueError(f"enum {enum_name} has no closing brace")

    body = source[open_index + 1:close_index]
    entries: List[str] = []
    current: List[str] = []
    depths = {"{": 0, "(": 0, "[": 0, "<": 0}
    closing = {"}": "{", ")": "(", "]": "[", ">": "<"}
    for char in body:
        if char in depths:
            depths[char] += 1
        elif char in closing and depths[closing[char]] > 0:
            depths[closing[char]] -= 1
        if char == "," and all(depth == 0 for depth in depths.values()):
            entries.append("".join(current))
            current = []
        else:
            current.append(char)
    if "".join(current).strip():
        entries.append("".join(current))

    variants: set[str] = set()
    for entry in entries:
        variant = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", entry)
        if variant:
            variants.add(variant.group(1))
    return variants


def gap_reason_for_lane(evidence_path, lane: str) -> Optional[str]:
    """Return a classified gap if this case is skipped in the given lane."""
    key = normalized_repo_path(evidence_path)
    if lane == "check":
        return CHECK_ONLY_GAPS.get(key)
    if lane not in POSITIVE_PARITY_LANES:
        return None
    if key in SHARED_POSITIVE_GAPS:
        return SHARED_POSITIVE_GAPS[key]
    return None


def strip_ansi(text: str) -> str:
    """Remove terminal colour escapes before parsing stable CLI contracts."""
    return ANSI_ESCAPE_RE.sub("", text)


def process_output(result: subprocess.CompletedProcess) -> str:
    """Return stdout and stderr in the same order used by companion checks."""
    return (result.stdout or "") + (result.stderr or "")


def llm_diagnostics(
    output: str,
) -> Tuple[Optional[List[Dict[str, Any]]], Optional[str]]:
    """Strictly decode one complete formatter-v1 JSON channel."""
    clean = output.strip()
    if not clean:
        return None, "expected formatter-v1 JSON diagnostics, got an empty channel"
    try:
        document = json.loads(clean)
    except json.JSONDecodeError as exc:
        return None, f"diagnostic channel is not exactly one JSON object: {exc.msg}"
    return validate_llm_document(document)


def module_llm_diagnostics(
    output: str,
) -> Tuple[Optional[List[Dict[str, Any]]], Optional[str]]:
    """Decode exactly ``<formatter JSON>\nCompilation failed[\n]``."""
    clean = output.replace("\r\n", "\n")
    if clean.endswith("\n"):
        clean = clean[:-1]
    suffix = "\nCompilation failed"
    if not clean.endswith(suffix):
        return None, (
            "module LLM stderr must be one JSON object followed by "
            "'Compilation failed'"
        )
    json_text = clean[:-len(suffix)]
    if json_text != json_text.strip():
        return None, "module LLM JSON has unexpected surrounding whitespace"
    try:
        document = json.loads(json_text)
    except json.JSONDecodeError as exc:
        return None, f"module diagnostic prefix is not exactly one JSON object: {exc.msg}"
    return validate_llm_document(document)


def validate_llm_document(
    document: Any,
) -> Tuple[Optional[List[Dict[str, Any]]], Optional[str]]:
    """Validate the stable formatter-v1 envelope and diagnostic array."""
    if not isinstance(document, dict):
        return None, "expected diagnostic JSON top level to be an object"
    if document.get("version") != 1:
        return None, f"expected diagnostic JSON version 1, got {document.get('version')!r}"
    items = document.get("diagnostics")
    if not isinstance(items, list) or not items:
        return None, "expected a non-empty diagnostics array"
    diagnostics: List[Dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            return None, "diagnostics array contains a non-object entry"
        diagnostics.append(item)
    return diagnostics, None


def diagnostic_by_code(
    diagnostics: List[Dict[str, Any]], code: str,
) -> Optional[Dict[str, Any]]:
    """Return the first diagnostic with an exact stable code."""
    return next((item for item in diagnostics if item.get("code") == code), None)


def expected_gap_lanes(scope: str, evidence: str,
                       members: dict[str, set[str]]) -> Optional[set[str]]:
    """Return the exact skipped lanes for a classified matrix gap."""
    if scope == "check-only":
        return {"check"}
    if evidence in members["e2e-c"]:
        if scope == "shared-positive":
            return {"e2e-c"}
    if evidence in members["golden-c"]:
        if scope == "shared-positive":
            return {"golden-c"}
    if evidence in members["native-c"]:
        if scope == "shared-positive":
            return {"native-c"}
    if evidence in members["module-c"]:
        if scope == "shared-positive":
            return {"module-c"}
    return None


def expected_covered_lanes(
    evidence: str,
    members: dict[str, set[str]],
) -> Optional[set[str]]:
    """Return the complete executable bundle required for covered evidence."""
    bundles = [
        ("c-structural", {"c-structural"}),
        ("golden-c", {"golden-c"}),
        ("e2e-c", {"e2e-c"}),
        ("native-c", {"native-c"}),
        ("module-c", {"module-c"}),
        ("check", {"check"}),
        ("self-compile-c", {"self-compile-c"}),
    ]
    for membership_lane, bundle in bundles:
        if evidence in members[membership_lane]:
            return bundle
    return None


def validate_parity_matrix(
    matrix_data: Optional[dict] = None,
    gap_tables: Optional[dict[str, dict[str, str]]] = None,
) -> Tuple[List[dict], List[str]]:
    """Validate matrix schema, enum closure, lanes, evidence, and gap closure."""
    errors: List[str] = []
    if matrix_data is None:
        try:
            raw = json.loads(PARITY_MATRIX.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            return [], [f"cannot read parity matrix: {exc}"]
    else:
        raw = matrix_data
    active_gap_tables = (
        PARITY_GAP_TABLES if gap_tables is None else gap_tables
    )

    if not isinstance(raw, dict):
        return [], ["matrix root must be an object"]
    if raw.get("schema_version") != 1:
        errors.append("schema_version must equal 1")
    features = raw.get("features")
    if not isinstance(features, list):
        return [], errors + ["features must be a list"]

    members = parity_lane_members()
    errors.extend(structural_fixture_integrity_errors())
    expected_scopes = set(PARITY_GAP_TABLES)
    if set(active_gap_tables) != expected_scopes:
        errors.append(
            f"gap table scopes {sorted(active_gap_tables)} != "
            f"{sorted(expected_scopes)}"
        )
    for scope, table in active_gap_tables.items():
        if not isinstance(table, dict):
            errors.append(f"{scope}: gap table must be an object")
            continue
        for path_text, gap_reason in table.items():
            if (
                not isinstance(path_text, str)
                or "\\" in path_text
                or Path(path_text).is_absolute()
            ):
                errors.append(f"{scope}: invalid normalized gap path {path_text!r}")
                continue
            try:
                normalized = normalized_repo_path(path_text)
            except ValueError:
                errors.append(f"{scope}: gap path escapes repository: {path_text}")
                continue
            if normalized != path_text:
                errors.append(
                    f"{scope}: gap path is not normalized: {path_text}"
                )
            if not isinstance(gap_reason, str) or not gap_reason:
                errors.append(f"{scope}: empty gap reason for {path_text}")

    valid_gap_tables = {
        scope: table for scope, table in active_gap_tables.items()
        if isinstance(table, dict)
    }
    scopes = sorted(valid_gap_tables)
    for index, left_scope in enumerate(scopes):
        for right_scope in scopes[index + 1:]:
            overlap = sorted(
                set(valid_gap_tables[left_scope])
                & set(valid_gap_tables[right_scope])
            )
            if overlap:
                errors.append(
                    f"gap tables {left_scope}/{right_scope} overlap: "
                    f"{', '.join(overlap)}"
                )

    required = {"feature_id", "evidence", "oracle", "lane", "status", "reason"}
    seen_ids: set[str] = set()
    valid_rows: List[dict] = []
    gap_cases: dict[str, dict[str, str]] = {
        scope: {} for scope in valid_gap_tables
    }

    for index, row in enumerate(features):
        label = f"features[{index}]"
        if not isinstance(row, dict):
            errors.append(f"{label} must be an object")
            continue
        missing = sorted(required - set(row))
        if missing:
            errors.append(f"{label} missing fields: {', '.join(missing)}")
            continue

        feature_id = row["feature_id"]
        evidence = row["evidence"]
        oracle = row["oracle"]
        lanes = row["lane"]
        status = row["status"]
        reason = row["reason"]

        if not isinstance(feature_id, str) or not feature_id:
            errors.append(f"{label}.feature_id must be a non-empty string")
            continue
        if feature_id in seen_ids:
            errors.append(f"duplicate feature_id: {feature_id}")
        seen_ids.add(feature_id)
        label = feature_id

        if (
            not isinstance(evidence, list) or not evidence
            or any(not isinstance(item, str) or not item for item in evidence)
        ):
            errors.append(f"{label}: evidence must be a non-empty string list")
            continue
        if len(evidence) != len(set(evidence)):
            errors.append(f"{label}: evidence paths must be unique")
        if (
            not isinstance(lanes, list) or not lanes
            or any(not isinstance(lane, str) for lane in lanes)
        ):
            errors.append(f"{label}: lane must be a non-empty string list")
            continue
        if len(lanes) != len(set(lanes)):
            errors.append(f"{label}: lanes must be unique")
        unknown_lanes = sorted(set(lanes) - PARITY_LANES)
        if unknown_lanes:
            errors.append(f"{label}: unknown lanes: {', '.join(unknown_lanes)}")
        if not isinstance(status, str) or status not in PARITY_STATUSES:
            errors.append(f"{label}: invalid status {status!r}")
            continue
        if not isinstance(oracle, str) or not oracle:
            errors.append(f"{label}: oracle must be a non-empty string")
        if not isinstance(reason, str) or not reason:
            errors.append(f"{label}: reason must be a non-empty string")

        if status == "manual-evidence" and set(lanes) != {"manual-source"}:
            errors.append(f"{label}: manual-evidence requires manual-source lane")
        if status == "covered" and "manual-source" in lanes:
            errors.append(f"{label}: covered evidence cannot use manual-source")
        if status != "manual-evidence" and set(lanes) == {"manual-source"}:
            errors.append(f"{label}: manual-source must be manual-evidence")

        for evidence_text in evidence:
            if "\\" in evidence_text or Path(evidence_text).is_absolute():
                errors.append(
                    f"{label}: evidence must be normalized repo-relative: "
                    f"{evidence_text}"
                )
                continue
            evidence_path = (REPO / evidence_text).resolve()
            try:
                evidence_path.relative_to(REPO.resolve())
            except ValueError:
                errors.append(f"{label}: evidence escapes repository: {evidence_text}")
                continue
            if not evidence_path.is_file():
                errors.append(f"{label}: evidence file missing: {evidence_text}")
                continue

            if status == "covered":
                gap_scopes = sorted(
                    scope for scope, table in valid_gap_tables.items()
                    if evidence_text in table
                )
                if gap_scopes:
                    errors.append(
                        f"{label}: covered evidence is present in gap table(s) "
                        f"{', '.join(gap_scopes)}: {evidence_text}"
                    )
                required_bundle = expected_covered_lanes(
                    evidence_text, members)
                if required_bundle is None:
                    errors.append(
                        f"{label}: covered evidence has no supported runner bundle: "
                        f"{evidence_text}"
                    )
                elif set(lanes) != required_bundle:
                    errors.append(
                        f"{label}: covered lanes {sorted(lanes)} != complete "
                        f"bundle {sorted(required_bundle)} for {evidence_text}"
                    )
                if (
                    feature_id.startswith(
                        ("HExpr.", "HStmt.", "HDecl.", "Pattern."))
                    and required_bundle not in (
                        {"e2e-c"}, {"golden-c"}, {"native-c"}, {"module-c"})
                ):
                    errors.append(
                        f"{label}: HIR/Pattern covered evidence requires a "
                        "C executable/golden/module/native lane"
                    )
                if (
                    required_bundle in (
                        {"check"}, {"self-compile-c"}, {"c-structural"})
                    and not feature_id.startswith("backend.")
                ):
                    errors.append(
                        f"{label}: single-lane covered evidence is reserved "
                        "for backend.* surfaces"
                    )

            for lane in lanes:
                if lane == "manual-source":
                    continue
                if evidence_text not in members.get(lane, set()):
                    errors.append(
                        f"{label}: {evidence_text} is not collected by {lane}"
                    )
                    continue
                if lane == "check":
                    companion = evidence_path.with_suffix(".error")
                elif lane in {"self-compile-c", "c-structural"}:
                    companion = None
                else:
                    companion = evidence_path.with_suffix(".expected")
                if companion is not None and not companion.is_file():
                    errors.append(
                        f"{label}: missing {companion.suffix} companion for "
                        f"{evidence_text} in {lane}"
                    )

                if status == "covered":
                    gap_reason = gap_reason_for_lane(evidence_text, lane)
                    if gap_reason:
                        errors.append(
                            f"{label}: covered evidence is classified as a gap "
                            f"in {lane}: {evidence_path.name}"
                        )

        if status == "known-gap":
            scope = row.get("gap_scope")
            if not isinstance(scope, str) or scope not in valid_gap_tables:
                errors.append(f"{label}: invalid or missing gap_scope")
            elif len(evidence) != 1:
                errors.append(f"{label}: known-gap requires exactly one evidence path")
            else:
                case_name = evidence[0]
                table = valid_gap_tables[scope]
                if case_name not in table:
                    errors.append(
                        f"{label}: {case_name} is not classified in {scope}"
                    )
                else:
                    if table[case_name] != reason:
                        errors.append(
                            f"{label}: reason differs from runner gap classification"
                        )
                    if case_name in gap_cases[scope]:
                        errors.append(
                            f"{label}: duplicate matrix gap for {scope}/{case_name}"
                        )
                    gap_cases[scope][case_name] = feature_id
                    expected_lanes = expected_gap_lanes(
                        scope, evidence[0], members)
                    if expected_lanes is None:
                        errors.append(
                            f"{label}: gap evidence has no executable collection lane"
                        )
                    elif set(lanes) != expected_lanes:
                        errors.append(
                            f"{label}: gap lanes {sorted(lanes)} != "
                            f"{sorted(expected_lanes)}"
                        )
        elif "gap_scope" in row:
            errors.append(f"{label}: gap_scope is only valid for known-gap")

        valid_rows.append(row)

    # Structural fixtures and matrix rows form a closed two-way contract. A
    # newly added fixture, a deleted dependency, or an unrelated row claiming
    # this lane must all fail parity validation instead of silently weakening
    # the generated-C oracle.
    expected_structural = {
        feature_id: set(fixtures)
        for feature_id, fixtures in STRUCTURAL_ORACLE_FIXTURES.items()
    }
    actual_structural: dict[str, set[str]] = {}
    structural_paths = structural_fixture_paths()
    for row in valid_rows:
        feature_id = row.get("feature_id")
        evidence = row.get("evidence")
        lanes = row.get("lane")
        if not isinstance(evidence, list) or not isinstance(lanes, list):
            continue
        evidence_set = set(evidence)
        if "c-structural" in lanes:
            if row.get("status") != "covered":
                errors.append(
                    f"{feature_id}: c-structural evidence must be covered")
            actual_structural[feature_id] = evidence_set
        elif evidence_set & structural_paths:
            errors.append(
                f"{feature_id}: structural fixture evidence requires the "
                "c-structural lane")

    missing_features = sorted(set(expected_structural) - set(actual_structural))
    extra_features = sorted(set(actual_structural) - set(expected_structural))
    if missing_features:
        errors.append(
            "c-structural oracle rows missing from matrix: "
            + ", ".join(missing_features))
    if extra_features:
        errors.append(
            "orphan c-structural matrix rows: " + ", ".join(extra_features))
    for feature_id in sorted(set(expected_structural) & set(actual_structural)):
        if actual_structural[feature_id] != expected_structural[feature_id]:
            missing_evidence = sorted(
                expected_structural[feature_id] - actual_structural[feature_id])
            orphan_evidence = sorted(
                actual_structural[feature_id] - expected_structural[feature_id])
            details = []
            if missing_evidence:
                details.append("missing " + ", ".join(missing_evidence))
            if orphan_evidence:
                details.append("orphan " + ", ".join(orphan_evidence))
            errors.append(
                f"{feature_id}: fixture/matrix evidence mismatch "
                f"({'; '.join(details)})")

    # Every runner gap is present exactly once, and the matrix has no orphan gap.
    for scope, table in valid_gap_tables.items():
        matrix_cases = set(gap_cases[scope])
        table_cases = set(table)
        missing = sorted(table_cases - matrix_cases)
        extra = sorted(matrix_cases - table_cases)
        if missing:
            errors.append(f"{scope}: gaps missing from matrix: {', '.join(missing)}")
        if extra:
            errors.append(f"{scope}: orphan matrix gaps: {', '.join(extra)}")

    # The compiler enum declarations are the authority: adding a variant makes
    # this suite fail until an evidence mapping is added.
    enum_specs = [
        ("HExpr", REPO / "compiler" / "hir.ring"),
        ("HStmt", REPO / "compiler" / "hir.ring"),
        ("HDecl", REPO / "compiler" / "hir.ring"),
        ("Pattern", REPO / "compiler" / "ast.ring"),
    ]
    for enum_name, source_path in enum_specs:
        try:
            variants = extract_enum_variants(source_path, enum_name)
        except (OSError, ValueError) as exc:
            errors.append(str(exc))
            continue
        expected_ids = {f"{enum_name}.{variant}" for variant in variants}
        mapped_ids = {
            feature_id for feature_id in seen_ids
            if feature_id.startswith(f"{enum_name}.")
        }
        missing = sorted(expected_ids - mapped_ids)
        extra = sorted(mapped_ids - expected_ids)
        if missing:
            errors.append(
                f"{enum_name}: variants missing matrix evidence: "
                f"{', '.join(missing)}"
            )
        if extra:
            errors.append(
                f"{enum_name}: orphan variant mappings: {', '.join(extra)}"
            )

    errors.extend(companion_integrity_errors())

    return valid_rows, errors


def run_parity(collector: ResultCollector, *,
               name_filter: Optional[str] = None) -> None:
    """Validate parity evidence wiring without executing semantic programs."""
    suite = "parity"
    features, errors = validate_parity_matrix()
    if errors:
        for index, error in enumerate(errors, 1):
            collector.add(TestResult(
                TestResult.FAIL, suite, f"matrix validation {index}", error))
        return

    selected = [
        row for row in features
        if matches_filter(row["feature_id"], name_filter)
        or any(matches_filter(path, name_filter) for path in row["evidence"])
    ]
    for row in selected:
        detail = (
            f"{row['status']}; matrix/lane wiring only, semantic evidence "
            "not executed by parity suite"
        )
        if row["status"] == "covered":
            collector.add(TestResult(
                TestResult.PASS, suite, row["feature_id"], detail))
        else:
            collector.add(TestResult(
                TestResult.SKIP, suite, row["feature_id"],
                f"{detail}: {row['reason']}"))


# ---------------------------------------------------------------------------
# Self-compile suite
# ---------------------------------------------------------------------------

def run_self_compile(ring_exe: str, collector: ResultCollector, *,
                     name_filter: Optional[str] = None) -> None:
    """Regenerate the tracked C anchor and require an exact fixed point."""
    suite = "self-compile"
    # Coarse-grained: the whole suite is one unit; filter matches the suite name.
    if not matches_filter(suite, name_filter):
        return
    compiler_main = REPO / "compiler" / "main.ring"
    if not compiler_main.is_file():
        collector.add(TestResult(TestResult.FAIL, suite, "source",
                                 "compiler/main.ring not found"))
        return
    if not DIST_C_MAIN.is_file():
        collector.add(TestResult(TestResult.FAIL, suite, "anchor",
                                 "tracked compiler/dist-c/main.c not found"))
        return

    with tempfile.TemporaryDirectory(prefix="ring_selfcompile_") as tmpdir:
        try:
            r = ring_build(
                ring_exe,
                str(compiler_main),
                out_dir=tmpdir,
                extra_args=["--no-c-lines"],
                timeout=TIMEOUT_SELFCOMPILE,
                phase_suite=suite,
                phase_case="regenerate",
            )
        except subprocess.TimeoutExpired:
            collector.add(TestResult(
                TestResult.FAIL, suite, "regenerate",
                f"timed out ({TIMEOUT_SELFCOMPILE}s)"))
            return

        if r.returncode != 0:
            combined = (r.stdout or "") + (r.stderr or "")
            collector.add(TestResult(
                TestResult.FAIL, suite, "regenerate",
                f"exit {r.returncode}: {combined[:500]}"))
            return

        generated_c = Path(tmpdir) / "main.c"
        generated_o = Path(tmpdir) / "main.o"
        if not generated_c.is_file():
            collector.add(TestResult(
                TestResult.FAIL, suite, "generated C", "main.c not produced"))
            return
        if not generated_o.is_file():
            collector.add(TestResult(
                TestResult.FAIL, suite, "generated object", "main.o not produced"))
            return
        collector.add(TestResult(
            TestResult.PASS, suite, "generated object",
            "main.o produced by the tracked C-native compiler"))

        anchor_bytes = DIST_C_MAIN.read_bytes()
        generated_bytes = generated_c.read_bytes()
        anchor_hash = hashlib.sha256(anchor_bytes).hexdigest()
        generated_hash = hashlib.sha256(generated_bytes).hexdigest()
        if anchor_bytes != generated_bytes:
            collector.add(TestResult(
                TestResult.FAIL, suite, "tracked anchor fixed point",
                f"dist-c/main.c sha256={anchor_hash}, regenerated sha256={generated_hash}"))
            return
        collector.add(TestResult(
            TestResult.PASS, suite, "tracked anchor fixed point",
            f"byte-identical sha256={anchor_hash}"))


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def print_summary(collector: ResultCollector) -> None:
    """Print the final summary block."""
    print()
    print("=== Summary ===")
    summary = collector.summary()

    for suite_name in [
        "e2e", "golden", "self-compile", "structural", "parity",
        "ownership-vertical", "runner",
    ]:
        if suite_name not in summary:
            continue
        s = summary[suite_name]
        parts = [f"{s['pass']} pass", f"{s['fail']} fail"]
        if s.get("skip", 0) > 0:
            parts.append(f"{s['skip']} skip")
        print(f"  {suite_name}: {', '.join(parts)}")

    total_fail = collector.failures
    if total_fail > 0:
        print(f"\nExit code: 1 ({total_fail} failure{'s' if total_fail != 1 else ''})")
    else:
        total_pass = sum(1 for r in collector.results if r.status == TestResult.PASS)
        print(f"\nExit code: 0 (all {total_pass} tests passed)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _run_selected(args: argparse.Namespace) -> int:
    suites = args.suites or [
        "e2e", "golden", "self-compile", "structural", "parity",
        "ownership-vertical",
    ]

    # --- Tool discovery ---
    needs_ring = any(
        suite in suites
        for suite in [
            "e2e", "golden", "self-compile", "structural",
            "ownership-vertical",
        ]
    )
    needs_clang = needs_ring
    clang_path = find_clang() if needs_clang else None
    try:
        ring_exe = find_ring_exe() if needs_ring else None
    except (
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        CompilerPreparationError,
        OSError,
    ) as exc:
        _report_compiler_preparation_failure(exc)
        return 1

    if needs_ring and ring_exe is None:
        print("ERROR: ring.exe not found.", file=sys.stderr)
        print("  Expected tracked compiler/dist-c/main.c and a working C toolchain.",
              file=sys.stderr)
        return 1

    if needs_clang and clang_path is None:
        print("ERROR: clang not found (required for executable/codegen suites).",
              file=sys.stderr)
        return 1

    # Ensure runtime .o is built
    needs_runtime = any(
        suite in suites for suite in ["e2e", "golden", "ownership-vertical"])
    if needs_runtime and clang_path:
        if not ensure_runtime(clang_path):
            print("ERROR: failed to build ring_runtime.o from ring_runtime.cpp.", file=sys.stderr)
            return 1

    if ring_exe:
        print(f"ring.exe: {ring_exe}")
    if clang_path:
        print(f"clang:    {clang_path}")
    print(f"suites:   {', '.join(suites)}")
    if args.name_filter:
        print(f"filter:   {args.name_filter}")
    print()

    collector = ResultCollector()

    if "e2e" in suites:
        _run_timed_suite("e2e", lambda: run_e2e(
            ring_exe, clang_path or "", collector,
            name_filter=args.name_filter,
        ))

    if "golden" in suites:
        _run_timed_suite("golden", lambda: run_golden(
            ring_exe, clang_path or "", collector,
            update_golden=args.update_golden,
            name_filter=args.name_filter,
        ))

    if "self-compile" in suites:
        _run_timed_suite("self-compile", lambda: run_self_compile(
            ring_exe, collector, name_filter=args.name_filter,
        ))

    if "structural" in suites:
        _run_timed_suite("structural", lambda: run_structural(
            ring_exe, collector, name_filter=args.name_filter,
        ))

    if "parity" in suites:
        _run_timed_suite("parity", lambda: run_parity(
            collector, name_filter=args.name_filter,
        ))

    if "ownership-vertical" in suites:
        _run_timed_suite("ownership-vertical", lambda: run_ownership_vertical_suite(
            ring_exe, clang_path or "", collector,
            name_filter=args.name_filter,
        ))

    if args.name_filter and not collector.results:
        collector.add(TestResult(
            TestResult.FAIL, "runner", "filter",
            f"no selected suite matched {args.name_filter!r}"))

    print_summary(collector)
    return 1 if collector.failures > 0 else 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Ring-lang Python test runner (B-151 P2)")
    parser.add_argument(
        "--suite",
        choices=[
            "e2e", "golden", "self-compile", "structural", "parity",
            "ownership-vertical",
        ],
        action="append", dest="suites",
        help="Test suite(s) to run. Omit for all C-native suites.")
    parser.add_argument(
        "--filter", dest="name_filter", metavar="SUBSTR", default=None,
        help="Only run cases whose name contains SUBSTR (case-insensitive, "
             "applies to all suites).")
    parser.add_argument(
        "--update-golden", action="store_true",
        help="Regenerate .expected golden snapshots instead of comparing.")
    parser.add_argument(
        "--phase-timing", type=_phase_timing_path, metavar="ABSOLUTE_JSONL",
        default=None,
        help="Write opt-in monotonic phase timings as JSONL to an absolute path.")
    args = parser.parse_args()

    if args.phase_timing is None:
        return _run_selected(args)

    try:
        tracer = PhaseTimingTrace(args.phase_timing)
    except OSError as exc:
        parser.error(f"cannot open --phase-timing output: {exc}")

    global _PHASE_TRACER
    _PHASE_TRACER = tracer
    try:
        try:
            exit_code = _run_selected(args)
        except BaseException as exc:
            outcome = "exception"
            trace_exit_code: Optional[int] = None
            if isinstance(exc, subprocess.TimeoutExpired):
                outcome = "timeout"
            elif isinstance(exc, subprocess.CalledProcessError):
                outcome = "nonzero"
                trace_exit_code = exc.returncode
            elif isinstance(exc, KeyboardInterrupt):
                outcome = "interrupted"
            try:
                tracer.finish(
                    complete=False, outcome=outcome,
                    exit_code=trace_exit_code,
                )
            except Exception:
                # Preserve the original runner failure if trace finalization also
                # fails; successfully emitted records have already been flushed.
                pass
            try:
                tracer.close()
            except Exception:
                pass
            raise

        try:
            tracer.finish(
                complete=True,
                outcome="success" if exit_code == 0 else "failure",
                exit_code=exit_code,
            )
        finally:
            tracer.close()
        return exit_code
    finally:
        _PHASE_TRACER = None


if __name__ == "__main__":
    sys.exit(main())
