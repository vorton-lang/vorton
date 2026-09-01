from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / ".agents" / "scripts"
ENTRY_PATH = SCRIPTS / "one_shot_entry.py"
GATE_PATH = SCRIPTS / "one_shot_gate.py"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(REPO_ROOT / "bench" / "check"))

import one_shot_entry as entry  # noqa: E402
import one_shot_gate as gate  # noqa: E402
import windows_job  # noqa: E402


MIB = 1024 * 1024


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def json_bytes(value) -> bytes:
    return (
        json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
    ).encode("ascii")


def controlled_env() -> dict[str, str]:
    python_dir = str(Path(sys.executable).resolve().parent)
    if os.name != "nt":
        return {
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": os.pathsep.join((python_dir, "/usr/bin", "/bin")),
        }
    system_root = os.environ.get("SystemRoot", r"C:\Windows")
    return {
        "PATH": os.pathsep.join((python_dir, str(Path(system_root) / "System32"))),
        "SystemRoot": system_root,
        "WINDIR": os.environ.get("WINDIR", system_root),
    }


def plan_limits(*, stdout_cap: int = 4096, stderr_cap: int = 4096) -> dict:
    return {
        "wall_seconds": 10.0,
        "stdout_cap_bytes": stdout_cap,
        "stderr_cap_bytes": stderr_cap,
        "job_memory_bytes": 256 * MIB if os.name == "nt" else None,
        "active_process_limit": 4 if os.name == "nt" else None,
        "poll_ms": 10,
    }


def make_plan(
    launcher_path: Path,
    *,
    code: str = "print('entry-ok')",
    argv: list[str] | None = None,
    env: dict[str, str] | None = None,
    stdout_cap: int = 4096,
    stderr_cap: int = 4096,
) -> dict:
    launcher = launcher_path.resolve(strict=True)
    windows_adapter = (
        REPO_ROOT / "bench" / "check" / "windows_job.py"
    ).resolve(strict=True)
    child_env = controlled_env() if env is None else env
    child_argv = (
        [
            str(Path(sys.executable).resolve()),
            "-I",
            "-S",
            "-B",
            "-u",
            "-c",
            code,
        ]
        if argv is None
        else argv
    )
    return {
        "schema": gate.ENTRY_PLAN_SCHEMA,
        "contract_version": 1,
        "gate_id": "outer-entry-synthetic",
        "launcher": {
            "path": str(launcher),
            "size": launcher.stat().st_size,
            "sha256": sha256_file(launcher),
            "windows_adapter": {
                "path": str(windows_adapter),
                "size": windows_adapter.stat().st_size,
                "sha256": sha256_file(windows_adapter),
            },
        },
        "inner": {
            "evidence_dir": "inner",
            "argv": child_argv,
            "cwd": str(REPO_ROOT.resolve()),
            "env": [
                {"name": name, "value": value}
                for name, value in sorted(child_env.items())
            ],
            "limits": plan_limits(
                stdout_cap=stdout_cap, stderr_cap=stderr_cap
            ),
            "success_exit_codes": [0],
        },
    }


def write_plan(path: Path, plan: dict) -> None:
    path.write_bytes(json_bytes(plan))


def outer_env_hash(environment: dict[str, str]) -> str:
    normalized = {
        (name.upper() if os.name == "nt" else name): value
        for name, value in environment.items()
    }
    entries = [
        {"name": name, "value": value}
        for name, value in sorted(normalized.items())
    ]
    return hashlib.sha256(json_bytes(entries)).hexdigest()


def entry_command(
    root: Path,
    plan_path: Path,
    environment: dict[str, str],
    *,
    outer_wall: float = 10.0,
    outer_cap: int = 64 * 1024,
) -> list[str]:
    python = Path(sys.executable).resolve(strict=True)
    entry_path = ENTRY_PATH.resolve(strict=True)
    plan = plan_path.resolve(strict=True)
    return [
        str(python),
        "-I",
        "-S",
        "-B",
        "-u",
        str(entry_path),
        "--evidence-root",
        str(root.resolve(strict=True)),
        "--plan",
        str(plan),
        "--plan-size",
        str(plan.stat().st_size),
        "--plan-sha256",
        sha256_file(plan),
        "--python",
        str(python),
        "--python-size",
        str(python.stat().st_size),
        "--python-sha256",
        sha256_file(python),
        "--python-version",
        sys.version,
        "--entry",
        str(entry_path),
        "--entry-size",
        str(entry_path.stat().st_size),
        "--entry-sha256",
        sha256_file(entry_path),
        "--outer-cwd",
        str(REPO_ROOT.resolve()),
        "--outer-env-sha256",
        outer_env_hash(environment),
        "--outer-wall-seconds",
        str(outer_wall),
        "--outer-output-cap",
        str(outer_cap),
    ]


def run_entry(root: Path, plan_path: Path, *, command=None, environment=None):
    env = controlled_env() if environment is None else environment
    argv = entry_command(root, plan_path, env) if command is None else command
    return subprocess.run(
        argv,
        cwd=REPO_ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=20,
        check=False,
    )


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="ascii"))


def process_exists(pid: int) -> bool:
    if os.name == "nt":
        handle = windows_job._open_process(pid)
        if handle is None:
            return False
        windows_job._close_handle(handle)
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_process_gone(pid: int, timeout: float = 8) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_exists(pid):
            return True
        time.sleep(0.05)
    return not process_exists(pid)


class OneShotEntryTests(unittest.TestCase):
    def test_success_hash_chain_raw_identity_and_retry_rejection(self) -> None:
        code = (
            "import sys;sys.stdout.buffer.write(b'inner-unique-out\\n');"
            "sys.stderr.buffer.write(b'inner-unique-err\\n')"
        )
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "evidence"
            root.mkdir()
            plan_path = base / "plan.json"
            write_plan(plan_path, make_plan(GATE_PATH, code=code))
            command = entry_command(root, plan_path, controlled_env())
            result = run_entry(root, plan_path, command=command)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            audit = gate.audit_outer(root)
            self.assertEqual(audit["state"], "complete", audit)
            self.assertEqual(audit["status"], "success", audit)

            outer_attempt = load_json(root / entry.OUTER_ATTEMPT_NAME)
            outer_verdict = load_json(root / entry.OUTER_VERDICT_NAME)
            inner_attempt = load_json(root / "inner" / gate.ATTEMPT_NAME)
            inner_verdict = load_json(root / "inner" / gate.VERDICT_NAME)
            self.assertEqual(
                gate.audit_attempt(root / "inner")["state"], "complete"
            )
            self.assertEqual(inner_attempt["schema"], gate.CHAINED_ATTEMPT_SCHEMA)
            self.assertEqual(inner_verdict["schema"], gate.CHAINED_VERDICT_SCHEMA)
            self.assertEqual(
                inner_attempt["chain"]["outer_attempt_sha256"],
                hashlib.sha256((root / entry.OUTER_ATTEMPT_NAME).read_bytes()).hexdigest(),
            )
            self.assertEqual(
                inner_attempt["chain"]["plan_sha256"], sha256_file(plan_path)
            )
            self.assertEqual(
                inner_attempt["chain"], inner_verdict["chain"]
            )
            self.assertEqual(
                (root / "inner" / gate.STDOUT_NAME).read_bytes(),
                b"inner-unique-out\n",
            )
            self.assertEqual(
                (root / "inner" / gate.STDERR_NAME).read_bytes(),
                b"inner-unique-err\n",
            )
            self.assertEqual(outer_verdict["inner"]["audit"]["state"], "complete")
            self.assertEqual(
                outer_verdict["inner"]["audit"],
                gate.audit_attempt(root / "inner"),
            )
            archive = base / "outer-evidence.tar"
            manifest = gate.create_archive(root, archive)
            self.assertEqual(gate.verify_archive(archive), manifest)
            self.assertGreaterEqual(manifest["file_count"], 8)
            before = {
                path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in root.rglob("*")
                if path.is_file()
            }
            retry = run_entry(root, plan_path, command=command)
            self.assertNotEqual(retry.returncode, 0)
            after = {
                path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in root.rglob("*")
                if path.is_file()
            }
            self.assertEqual(after, before)
            self.assertEqual(outer_attempt["delivery"]["env_sha256"], outer_env_hash(controlled_env()))

    def test_child_nonzero_and_output_cap_keep_exact_inner_raw(self) -> None:
        cases = (
            (
                "nonzero",
                "import sys;sys.stdout.buffer.write(b'before-nonzero\\n');"
                "sys.stderr.buffer.write(b'unique-child-error\\n');raise SystemExit(7)",
                4096,
                "child_nonzero",
                b"before-nonzero\n",
            ),
            (
                "cap",
                "import sys;sys.stdout.buffer.write(b'Z'*8192);sys.stdout.flush()",
                37,
                "output_limit",
                b"Z" * 37,
            ),
        )
        for label, code, stdout_cap, inner_class, expected_stdout in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                root = base / "evidence"
                root.mkdir()
                plan_path = base / "plan.json"
                write_plan(
                    plan_path,
                    make_plan(GATE_PATH, code=code, stdout_cap=stdout_cap),
                )
                result = run_entry(root, plan_path)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(gate.audit_outer(root)["state"], "complete")
                inner = load_json(root / "inner" / gate.VERDICT_NAME)
                self.assertEqual(inner["classification"], inner_class)
                outer = load_json(root / entry.OUTER_VERDICT_NAME)
                self.assertEqual(outer["status"], "failure")
                self.assertEqual(outer["classification"], "inner_failure")
                outer_audit = gate.audit_outer(root)
                self.assertEqual(outer_audit["status"], "failure", outer_audit)
                self.assertEqual(
                    (root / "inner" / gate.STDOUT_NAME).read_bytes(), expected_stdout
                )

    def test_second_stage_failures_are_durable_after_outer_attempt(self) -> None:
        launchers = {
            "syntax": ("def broken(:\n", "SyntaxError"),
            "import": ("import vorton_missing_outer_module\n", "ModuleNotFoundError"),
            "dataclass": (
                "from dataclasses import dataclass\n"
                "@dataclass\nclass Good:\n    value: int\n"
                "raise RuntimeError('dataclass-after-registration')\n",
                "dataclass-after-registration",
            ),
            "dataclass-error": (
                "from dataclasses import dataclass\n"
                "@dataclass\nclass Bad:\n    first: int = 1\n    second: int\n",
                "non-default argument",
            ),
            "site": (
                "import site\nraise RuntimeError('site-stage-marker')\n",
                "site-stage-marker",
            ),
            "outer-streams": (
                "import os,sys\nprint('outer-unique-out')\n"
                "print('outer-unique-err',file=sys.stderr)\n"
                "os.write(1,b'outer-direct-out\\n')\n"
                "os.write(2,b'outer-direct-err\\n')\n"
                "raise RuntimeError('outer-stream-stage-marker')\n",
                "outer-stream-stage-marker",
            ),
        }
        for label, (source, marker) in launchers.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                root = base / "evidence"
                root.mkdir()
                launcher = base / "launcher.py"
                launcher.write_text(source, encoding="utf-8")
                plan_path = base / "plan.json"
                write_plan(plan_path, make_plan(launcher))
                result = run_entry(root, plan_path)
                self.assertNotEqual(result.returncode, 0)
                audit = gate.audit_outer(root)
                self.assertEqual(audit["state"], "complete", audit)
                self.assertIn(
                    marker,
                    (root / entry.OUTER_STDERR_NAME).read_text(
                        encoding="utf-8", errors="replace"
                    ),
                )
                if label == "outer-streams":
                    self.assertIn(
                        "outer-unique-out",
                        (root / entry.OUTER_STDOUT_NAME).read_text(
                            encoding="utf-8", errors="replace"
                        ),
                    )
                    self.assertIn(
                        "outer-unique-err",
                        (root / entry.OUTER_STDERR_NAME).read_text(
                            encoding="utf-8", errors="replace"
                        ),
                    )
                    self.assertIn(
                        b"outer-direct-out",
                        (root / entry.OUTER_STDOUT_NAME).read_bytes(),
                    )
                    self.assertIn(
                        b"outer-direct-err",
                        (root / entry.OUTER_STDERR_NAME).read_bytes(),
                    )
                self.assertFalse((root / "inner" / gate.ATTEMPT_NAME).exists())

        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "evidence"
            root.mkdir()
            plan_path = base / "plan.json"
            invalid = make_plan(GATE_PATH)
            invalid["schema"] = "wrong-schema"
            write_plan(plan_path, invalid)
            self.assertNotEqual(run_entry(root, plan_path).returncode, 0)
            self.assertEqual(gate.audit_outer(root)["state"], "complete")
            self.assertIn(
                "schema/version mismatch",
                (root / entry.OUTER_STDERR_NAME).read_text(errors="replace"),
            )

        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "evidence"
            root.mkdir()
            plan_path = base / "plan.json"
            missing = base / "missing-child-python"
            write_plan(
                plan_path,
                make_plan(GATE_PATH, argv=[str(missing), "-c", "pass"]),
            )
            self.assertNotEqual(run_entry(root, plan_path).returncode, 0)
            self.assertEqual(gate.audit_outer(root)["state"], "complete")
            self.assertIn(
                "argv[0]",
                (root / entry.OUTER_STDERR_NAME).read_text(errors="replace"),
            )

    def test_outer_output_cap_is_exact_and_durable(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "evidence"
            root.mkdir()
            launcher = base / "outer-cap-launcher.py"
            launcher.write_text(
                "import sys\nsys.stdout.write('Q' * 8192)\n",
                encoding="utf-8",
            )
            plan_path = base / "plan.json"
            write_plan(plan_path, make_plan(launcher))
            environment = controlled_env()
            command = entry_command(
                root, plan_path, environment, outer_cap=1024
            )
            result = run_entry(
                root, plan_path, command=command, environment=environment
            )
            self.assertNotEqual(result.returncode, 0)
            verdict = load_json(root / entry.OUTER_VERDICT_NAME)
            self.assertEqual(verdict["classification"], "outer_output_limit")
            self.assertEqual(
                (root / entry.OUTER_STDOUT_NAME).read_bytes(),
                b"Q" * 1024,
            )
            self.assertTrue(verdict["streams"]["stdout"]["truncated_at_cap"])
            self.assertEqual(gate.audit_outer(root)["state"], "complete")

    def test_outer_launcher_wall_bound_is_durable(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "evidence"
            root.mkdir()
            launcher = base / "slow-launcher.py"
            launcher.write_text(
                "import time\ntime.sleep(5)\n",
                encoding="utf-8",
            )
            plan_path = base / "plan.json"
            write_plan(plan_path, make_plan(launcher))
            environment = controlled_env()
            command = entry_command(
                root, plan_path, environment, outer_wall=0.1
            )
            started = time.monotonic()
            result = run_entry(
                root, plan_path, command=command, environment=environment
            )
            self.assertLess(time.monotonic() - started, 3)
            self.assertNotEqual(result.returncode, 0)
            audit = gate.audit_outer(root)
            self.assertTrue(audit["consumed"], audit)
            self.assertIn(audit["state"], {"complete", "incomplete"}, audit)
            if audit["state"] == "complete":
                verdict = load_json(root / entry.OUTER_VERDICT_NAME)
                self.assertEqual(verdict["classification"], "outer_timeout")
            else:
                self.assertEqual(audit["classification"], "unknown")

    def test_outer_wall_bound_cleans_running_inner_target(self) -> None:
        code = "import os,time;print(os.getpid(),flush=True);time.sleep(30)"
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "evidence"
            root.mkdir()
            plan_path = base / "plan.json"
            write_plan(plan_path, make_plan(GATE_PATH, code=code))
            environment = controlled_env()
            command = entry_command(
                root, plan_path, environment, outer_wall=0.2
            )
            started = time.monotonic()
            result = run_entry(
                root, plan_path, command=command, environment=environment
            )
            self.assertLess(time.monotonic() - started, 4)
            self.assertNotEqual(result.returncode, 0)
            inner_stdout = root / "inner" / gate.STDOUT_NAME
            if inner_stdout.is_file() and inner_stdout.read_text().strip():
                pid = int(inner_stdout.read_text().strip())
                self.assertTrue(wait_process_gone(pid), pid)
            audit = gate.audit_outer(root)
            self.assertTrue(audit["consumed"], audit)
            self.assertIn(audit["state"], {"complete", "incomplete"}, audit)
            if audit["state"] == "complete":
                self.assertEqual(
                    load_json(root / entry.OUTER_VERDICT_NAME)["classification"],
                    "outer_timeout",
                )

    def test_nonfinite_and_bool_wall_fail_before_inner_attempt(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            for token in ("NaN", "Infinity", "-Infinity", "true"):
                root = base / f"evidence-{token.replace('-', 'neg')}"
                root.mkdir()
                marker = base / f"target-{token.replace('-', 'neg')}"
                plan_path = base / f"plan-{token.replace('-', 'neg')}.json"
                plan = make_plan(
                    GATE_PATH,
                    code=f"from pathlib import Path;Path({str(marker)!r}).write_text('ran')",
                )
                raw = json_bytes(plan).decode("ascii")
                self.assertIn('"wall_seconds": 10.0', raw)
                raw = raw.replace('"wall_seconds": 10.0', f'"wall_seconds": {token}')
                plan_path.write_text(raw, encoding="ascii")
                result = run_entry(root, plan_path)
                self.assertNotEqual(result.returncode, 0, token)
                audit = gate.audit_outer(root)
                self.assertEqual(audit["state"], "complete", (token, audit))
                self.assertFalse(marker.exists(), token)
                self.assertFalse((root / "inner" / gate.ATTEMPT_NAME).exists())

    def test_outer_crash_after_attempt_is_consumed_unknown_and_nonretry(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "evidence"
            root.mkdir()
            launcher = base / "crash-launcher.py"
            launcher.write_text("import os\nos._exit(93)\n", encoding="utf-8")
            plan_path = base / "plan.json"
            write_plan(plan_path, make_plan(launcher))
            command = entry_command(root, plan_path, controlled_env())
            result = run_entry(root, plan_path, command=command)
            self.assertEqual(result.returncode, 93)
            audit = gate.audit_outer(root)
            self.assertTrue(audit["consumed"])
            self.assertEqual(audit["state"], "incomplete")
            self.assertEqual(audit["classification"], "unknown")
            attempt_hash = sha256_file(root / entry.OUTER_ATTEMPT_NAME)
            retry = run_entry(root, plan_path, command=command)
            self.assertNotEqual(retry.returncode, 0)
            self.assertEqual(sha256_file(root / entry.OUTER_ATTEMPT_NAME), attempt_hash)

    def test_cleanup_callback_precedes_target_release(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            marker = base / "target-ran"
            stdout = base / "stdout.raw"
            stderr = base / "stderr.raw"
            limits = gate.Limits(
                wall_seconds=3,
                stdout_cap_bytes=1024,
                stderr_cap_bytes=1024,
                job_memory_bytes=128 * MIB if os.name == "nt" else None,
                active_process_limit=2 if os.name == "nt" else None,
            )
            calls = []

            def reject_handshake(value):
                calls.append(value)
                raise RuntimeError("stop-before-release")

            adapter = (
                windows_job.run_one_shot_job
                if os.name == "nt"
                else gate._run_non_windows_job
            )
            outcome = adapter(
                [
                    str(Path(sys.executable).resolve()),
                    "-I",
                    "-S",
                    "-c",
                    f"from pathlib import Path;Path({str(marker)!r}).write_text('ran')",
                ],
                cwd=REPO_ROOT,
                env=controlled_env(),
                stdout_path=stdout,
                stderr_path=stderr,
                limits=limits,
                cleanup_armed_callback=reject_handshake,
            )
            self.assertEqual(len(calls), 1)
            self.assertFalse(marker.exists())
            self.assertIn("stop-before-release", outcome["infrastructure_error"] or "")

    def test_outer_crash_after_handshake_cleans_root_and_descendant(self) -> None:
        grandchild = "import time;time.sleep(30)"
        code = (
            "import os,subprocess,sys,time\n"
            f"p=subprocess.Popen([sys.executable,'-I','-S','-c',{grandchild!r}])\n"
            "print(os.getpid(),p.pid,flush=True)\n"
            "time.sleep(30)\n"
        )
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "evidence"
            root.mkdir()
            plan_path = base / "plan.json"
            write_plan(plan_path, make_plan(GATE_PATH, code=code))
            environment = controlled_env()
            command = entry_command(root, plan_path, environment)
            process = subprocess.Popen(
                command,
                cwd=REPO_ROOT,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            inner_stdout = root / "inner" / gate.STDOUT_NAME
            line = ""
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                if inner_stdout.is_file():
                    line = inner_stdout.read_text(errors="ignore").strip()
                    if len(line.split()) == 2:
                        break
                if process.poll() is not None:
                    break
                time.sleep(0.05)
            self.assertEqual(len(line.split()), 2, (process.poll(), line))
            root_pid, child_pid = (int(value) for value in line.split())
            self.assertTrue(process_exists(root_pid))
            self.assertTrue(process_exists(child_pid))
            process.kill()
            process.wait(timeout=5)
            assert process.stdout is not None and process.stderr is not None
            process.stdout.close()
            process.stderr.close()
            self.assertTrue(wait_process_gone(root_pid), root_pid)
            self.assertTrue(wait_process_gone(child_pid), child_pid)
            audit = gate.audit_outer(root)
            self.assertTrue(audit["consumed"])
            self.assertEqual(audit["state"], "incomplete", audit)

    def test_source_ordering_preserves_internal_reliability_contract(self) -> None:
        sources = {
            "entry": ENTRY_PATH.read_text(encoding="utf-8"),
            "gate": GATE_PATH.read_text(encoding="utf-8"),
            "windows": (REPO_ROOT / "bench" / "check" / "windows_job.py").read_text(
                encoding="utf-8"
            ),
        }

        def errors(values):
            result = []
            entry_source = values["entry"]
            gate_source = values["gate"]
            windows_source = values["windows"]
            attempt = "_exclusive_write(attempt_path, _json_bytes(attempt))"
            raw = "stdout_fd = _open_outer_raw(root / OUTER_STDOUT_NAME)"
            plan = "plan_bytes = _read_exact("
            if not (attempt in entry_source and raw in entry_source and plan in entry_source):
                result.append("entry boundary token missing")
            elif not entry_source.index(attempt) < entry_source.index(raw) < entry_source.index(plan):
                result.append("entry reads plan before attempt/raw")
            if (
                entry_source.count("os.O_EXCL") < 2
                or entry_source.count("os.fsync(descriptor)") < 3
            ):
                result.append("outer attempt/raw lost O_EXCL+fsync")
            if "import one_shot_gate" in entry_source or "sys.path.insert" in entry_source:
                result.append("outer entry imports repo before dynamic boundary")
            if "OUTER_VERDICT_NAME).exists" in entry_source:
                result.append("outer verdict regained check-then-write authority")
            assign = "AssignProcessToJobObject(job, process_handle)"
            callback = "cleanup_armed_callback("
            resume = "ResumeThread(thread_handle)"
            if not (
                assign in windows_source
                and callback in windows_source
                and resume in windows_source
                and windows_source.index(assign)
                < windows_source.index(callback)
                < windows_source.index(resume)
            ):
                result.append("Windows target can resume before cleanup arm")
            posix_callback = "cleanup_armed_callback(\n            {"
            release = '_write_all_fd(release_write, b"G")'
            if not (
                posix_callback in gate_source
                and release in gate_source
                and gate_source.index(posix_callback) < gate_source.index(release)
            ):
                result.append("POSIX target can release before cleanup arm")
            if "if pgid is None or group_quiesced:" not in gate_source:
                result.append("watchdog can disarm before group quiescence")
            if not (
                gate_source.rfind("\n    _detach_outer_streams()\n")
                < gate_source.rfind("stdout = _outer_raw_record")
            ) or "\n    _detach_outer_streams()\n" not in gate_source:
                result.append("outer raw identity can be written after seal")
            if not (
                entry_source.rfind("_detach_outer_streams()")
                < entry_source.rfind("stdout = _raw_record(root / OUTER_STDOUT_NAME")
            ):
                result.append("bootstrap failure raw is not detached before seal")
            for token in ("allow_nan=False", "parse_constant=_reject_json_constant"):
                if token not in entry_source or token not in gate_source:
                    result.append(f"JSON non-finite guard missing {token}")
            if "math.isfinite" not in gate_source:
                result.append("float schema lacks finite-value validation")
            for forbidden in (
                "shell=True",
                "os.system(",
                "iprime-9585309c-gen1-launch-failure",
                "3161665E1DECFD81D4D8DC57943D1014",
            ):
                if forbidden in "\n".join(values.values()):
                    result.append(f"forbidden source token {forbidden}")
            return result

        self.assertEqual(errors(sources), [])


if __name__ == "__main__":
    unittest.main()
