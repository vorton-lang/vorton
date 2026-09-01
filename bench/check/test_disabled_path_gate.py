from __future__ import annotations

import copy
import io
import json
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import disabled_path_gate as gate
import run as harness


class DisabledPathGateTests(unittest.TestCase):
    def _subjects(self) -> list[dict[str, object]]:
        fixture = {
            "path": gate.FIXTURE_PATH,
            "bytes": 7,
            "sha256": "f" * 64,
        }
        prelude = [
            {"path": path, "bytes": 7, "sha256": f"{index + 1:064x}"}
            for index, path in enumerate(gate.STD_PATHS)
        ]
        return [
            {
                "subject": "base",
                "fixture": copy.deepcopy(fixture),
                "prelude_files": copy.deepcopy(prelude),
                "binary": {"raw_sha256": "a" * 64},
            },
            {
                "subject": "candidate",
                "fixture": copy.deepcopy(fixture),
                "prelude_files": copy.deepcopy(prelude),
                "binary": {"raw_sha256": "b" * 64},
            },
        ]

    def _invocation(
        self,
        root: Path,
        stage: dict[str, str],
        ordinal: int,
        subject: str,
        stem: str,
        *,
        write_streams: bool,
        wall_ns: int,
    ) -> dict[str, object]:
        stdout = root / "raw" / f"{stem}.stdout"
        stderr = root / "raw" / f"{stem}.stderr"
        if write_streams:
            stdout.parent.mkdir(parents=True, exist_ok=True)
            stdout.write_bytes(gate.EXPECTED_STDOUT)
            stderr.write_bytes(gate.EXPECTED_STDERR)
            stdout_record = gate._relative_file_record(stdout, root)
            stderr_record = gate._relative_file_record(stderr, root)
        else:
            stdout_record = {
                "path": f"raw/{stem}.stdout",
                "bytes": len(gate.EXPECTED_STDOUT),
                "sha256": "1" * 64,
            }
            stderr_record = {
                "path": f"raw/{stem}.stderr",
                "bytes": 0,
                "sha256": "2" * 64,
            }
        return {
            "ordinal": ordinal,
            "subject": subject,
            "binary_raw_sha256": "a" * 64 if subject == "base" else "b" * 64,
            "argv": [stage["invocation_binary"], "check", stage["fixture"]],
            "cwd": stage["cwd"],
            "timeout_seconds": gate.INVOCATION_TIMEOUT_SECONDS,
            "wall_ns": wall_ns,
            "exit_code": 0,
            "timed_out": False,
            "measurement_errors": [],
            "stdout": stdout_record,
            "stderr": stderr_record,
        }

    def _rows(
        self,
        root: Path,
        stage: dict[str, str],
        warmup_count: int,
        pair_count: int,
        *,
        write_streams: bool = False,
        candidate_wall_ns: int = 101_000_000,
    ) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
        ordinal = 0

        def make(kind: str, count: int) -> list[dict[str, object]]:
            nonlocal ordinal
            result = []
            for index in range(count):
                order = gate._expected_order(index)
                invocations = []
                for position, subject in enumerate(order):
                    invocations.append(
                        self._invocation(
                            root,
                            stage,
                            ordinal,
                            subject,
                            f"{kind}-{index}-{position}-{subject}",
                            write_streams=write_streams,
                            wall_ns=(
                                100_000_000
                                if subject == "base"
                                else candidate_wall_ns
                            ),
                        )
                    )
                    ordinal += 1
                result.append(
                    {"index": index, "order": order, "invocations": invocations}
                )
            return result

        return make("warmup", warmup_count), make("pair", pair_count)

    def test_schema_is_pinned_and_strict_loader_rejects_duplicate_keys(self) -> None:
        schema = gate._load_schema()
        self.assertEqual(schema["$id"], gate.SCHEMA_ID)
        shared_schema = {
            "type": "array",
            "minItems": 2,
            "maxItems": 2,
            "uniqueItems": True,
            "items": {"$ref": "#/$defs/name"},
            "$defs": {"name": {"type": "string", "enum": ["a", "b"]}},
        }
        harness.validate_json(["a", "b"], shared_schema)
        with self.assertRaises(harness.HarnessError):
            harness.validate_json(["a", "a"], shared_schema)
        with self.assertRaisesRegex(harness.DuplicateJsonKeyError, "duplicate JSON key"):
            harness._strict_json_loads('{"a":1,"a":2}', "fixture")

        changed = copy.deepcopy(schema)
        changed["title"] = "lax"
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "schema.json"
            path.write_text(json.dumps(changed), encoding="utf-8")
            with self.assertRaisesRegex(gate.GateError, "canonical contract"):
                gate._load_schema(path)

    def test_schema_accepts_only_the_exact_nested_evidence_shape(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            stage = gate._stage_layout(root)
            warmups, pairs = self._rows(
                root, stage, gate.WARMUP_PAIRS, gate.MEASURED_PAIRS
            )
            file_record = {"path": "raw/x", "bytes": 1, "sha256": "a" * 64}

            def command(phase: str) -> dict[str, object]:
                return {
                    "phase": phase,
                    "argv": ["tool", phase],
                    "cwd": stage["source"],
                    "timeout_seconds": gate.BUILD_TIMEOUT_SECONDS,
                    "wall_ns": 1,
                    "exit_code": 0,
                    "timed_out": False,
                    "measurement_errors": [],
                    "stdout": copy.deepcopy(file_record),
                    "stderr": copy.deepcopy(file_record),
                }

            subjects = []
            for sequence, name in enumerate(gate.SUBJECTS):
                subjects.append(
                    {
                        "subject": name,
                        "commit": ("a" if name == "base" else "b") * 40,
                        "build_sequence": sequence,
                        "anchor": {
                            "path": gate.ANCHOR_PATH,
                            "bytes": 1,
                            "sha256": "1" * 64,
                        },
                        "runtime": {
                            "path": gate.RUNTIME_PATH,
                            "bytes": 1,
                            "sha256": "2" * 64,
                        },
                        "fixture": {
                            "path": gate.FIXTURE_PATH,
                            "bytes": 1,
                            "sha256": "3" * 64,
                        },
                        "prelude_files": [
                            {
                                "path": path,
                                "bytes": 1,
                                "sha256": f"{index + 10:064x}",
                            }
                            for index, path in enumerate(gate.STD_PATHS)
                        ],
                        "gate": (
                            None
                            if name == "base"
                            else {
                                "path": gate.GATE_PATH,
                                "bytes": 1,
                                "sha256": "4" * 64,
                            }
                        ),
                        "schema_contract": (
                            None
                            if name == "base"
                            else {
                                "path": gate.SCHEMA_PATH,
                                "bytes": 1,
                                "sha256": "5" * 64,
                            }
                        ),
                        "harness": (
                            None
                            if name == "base"
                            else {
                                "path": gate.HARNESS_PATH,
                                "bytes": 1,
                                "sha256": "8" * 64,
                            }
                        ),
                        "windows_job": (
                            None
                            if name == "base"
                            else {
                                "path": gate.WINDOWS_JOB_PATH,
                                "bytes": 1,
                                "sha256": "9" * 64,
                            }
                        ),
                        "binary": {
                            "bytes": 1,
                            "raw_sha256": ("a" if name == "base" else "b") * 64,
                            "coff_normalized_sha256": "6" * 64,
                            "coff_timestamp_offset": 1,
                            "coff_timestamp_value": 1,
                        },
                        "build": [
                            command("anchor_compile"),
                            command("runtime_compile"),
                            command("link"),
                        ],
                        "linker_binding": {
                            "schema": harness.LINKER_BINDING_SCHEMA,
                            "probe_argv": ["clang", "-###", "link"],
                            "cwd": stage["source"],
                            "claimed_path": "C:/lld-link.exe",
                            "selected_path": "C:/lld-link.exe",
                            "exit_code": 0,
                            "stdout": copy.deepcopy(file_record),
                            "stderr": copy.deepcopy(file_record),
                        },
                    }
                )
            tools = {
                name: {
                    "path": f"C:/{name}.exe",
                    "bytes": 1,
                    "sha256": "7" * 64,
                    "version": "v1",
                }
                for name in ("git", "clang", "clangxx", "lld_link", "python")
            }
            power = {
                "active_scheme": "balanced",
                "ac_line_status": 1,
                "battery_flag": 1,
                "battery_life_percent": 50,
            }
            evidence = {
                "schema": gate.EVIDENCE_SCHEMA,
                "created_utc": "2026-08-07T00:00:00+00:00",
                "contract": gate._contract(),
                "repository": {
                    "path": str(root),
                    "base_commit": "a" * 40,
                    "candidate_commit": "b" * 40,
                },
                "stage": stage,
                "tools": tools,
                "flags": gate._flags(),
                "environment": {
                    "machine": {
                        "os_system": "Windows",
                        "os_release": "1",
                        "os_version": "1",
                        "machine": "AMD64",
                        "cpu": "CPU",
                        "logical_cores": 1,
                        "total_memory_bytes": 1,
                    },
                    "power_before": copy.deepcopy(power),
                    "power_after": copy.deepcopy(power),
                    "removed_phase_environment": [],
                },
                "subjects": subjects,
                "warmups": warmups,
                "pairs": pairs,
                "claimed_summary": gate._recompute_summary(pairs),
                "claimed_verdict": "PASS",
            }
            schema = gate._load_schema()
            harness.validate_json(evidence, schema)
            evidence["pairs"][0]["invocations"][0]["trusted_pass"] = True
            with self.assertRaisesRegex(harness.HarnessError, "unexpected key"):
                harness.validate_json(evidence, schema)
            del evidence["pairs"][0]["invocations"][0]["trusted_pass"]
            del evidence["subjects"][0]["prelude_files"]
            with self.assertRaisesRegex(harness.HarnessError, "missing required"):
                harness.validate_json(evidence, schema)

    def test_run_preflight_rejects_dirty_or_ref_mismatched_candidate(self) -> None:
        base, candidate = "a" * 40, "b" * 40
        gate._require_clean_candidate(base, candidate, candidate, base, candidate, b"")
        cases = {
            "dirty": (candidate, base, candidate, b" M compiler/cli.vorton\n"),
            "head_mismatch": (base, base, candidate, b""),
            "candidate_resolution": (candidate, base, "c" * 40, b""),
        }
        for name, (head, resolved_base, resolved_candidate, status) in cases.items():
            with self.subTest(name=name), self.assertRaises(gate.GateError):
                gate._require_clean_candidate(
                    base,
                    candidate,
                    head,
                    resolved_base,
                    resolved_candidate,
                    status,
                )

    def test_archive_fixture_asymmetry_is_rejected(self) -> None:
        subjects = self._subjects()
        gate._require_archive_symmetry(subjects)
        subjects[1]["fixture"]["sha256"] = "0" * 64  # type: ignore[index]
        with self.assertRaisesRegex(gate.GateError, "fixture archive bytes differ"):
            gate._require_archive_symmetry(subjects)

        subjects = self._subjects()
        subjects[1]["prelude_files"][0]["sha256"] = "e" * 64  # type: ignore[index]
        with self.assertRaisesRegex(gate.GateError, "prelude archive bytes differ"):
            gate._require_archive_symmetry(subjects)

    def test_archive_recipe_disables_checkout_eol_conversion(self) -> None:
        argv = gate._archive_argv(
            "C:/Git/git.exe",
            Path("C:/repo"),
            Path("C:/results/stage/base.tar"),
            "a" * 40,
        )
        self.assertEqual(
            argv,
            [
                "C:/Git/git.exe",
                "-c",
                "core.autocrlf=false",
                "-C",
                "C:\\repo",
                "archive",
                "--format=tar",
                "--output=C:\\results\\stage\\base.tar",
                "a" * 40,
            ],
        )

    def test_execution_closure_git_materializations_are_identical_lf(self) -> None:
        closure = (
            "bench/check/manifest.json",
            gate.HARNESS_PATH,
            gate.WINDOWS_JOB_PATH,
            gate.GATE_PATH,
            gate.SCHEMA_PATH,
        )
        for path in closure:
            attributes = subprocess.run(
                [
                    "git", "-C", str(gate.REPO_ROOT), "check-attr", "text", "eol",
                    "--", path,
                ],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=True,
            ).stdout
            self.assertIn("text: set", attributes, path)
            self.assertIn("eol: lf", attributes, path)

        head = subprocess.run(
            ["git", "-C", str(gate.REPO_ROOT), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            encoding="ascii",
            check=True,
        ).stdout.strip()
        archive_data = subprocess.run(
            [
                "git", "-C", str(gate.REPO_ROOT), "archive", "--format=tar",
                head, "--", *closure,
            ],
            capture_output=True,
            check=True,
        ).stdout
        with tarfile.open(fileobj=io.BytesIO(archive_data), mode="r:") as archive:
            archived = {}
            for path in closure:
                stream = archive.extractfile(path)
                self.assertIsNotNone(stream, path)
                assert stream is not None
                archived[path] = stream.read()

        with tempfile.TemporaryDirectory() as temp:
            checkout = Path(temp) / "checkout"
            subprocess.run(
                [
                    "git", "clone", "--quiet", "--shared", "--no-checkout",
                    str(gate.REPO_ROOT), str(checkout),
                ],
                capture_output=True,
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(checkout), "config", "core.autocrlf", "true"],
                capture_output=True,
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(checkout), "checkout", "--quiet", "--detach", head],
                capture_output=True,
                check=True,
            )
            for path in closure:
                committed = subprocess.run(
                    ["git", "-C", str(gate.REPO_ROOT), "show", f"{head}:{path}"],
                    capture_output=True,
                    check=True,
                ).stdout
                indexed = subprocess.run(
                    ["git", "-C", str(gate.REPO_ROOT), "show", f":{path}"],
                    capture_output=True,
                    check=True,
                ).stdout
                working = (gate.REPO_ROOT / path).read_bytes()
                checked_out = (checkout / path).read_bytes()
                values = (committed, indexed, archived[path], working, checked_out)
                self.assertEqual(len({harness._sha256_bytes(value) for value in values}), 1, path)
                self.assertNotIn(b"\r\n", committed, path)

    def test_contract_blob_preflight_runs_before_archive_work(self) -> None:
        def committed(_repo: Path, _git: str, _commit: str, path: str) -> bytes:
            return (gate.REPO_ROOT / path).read_bytes()

        with mock.patch.object(gate, "_git_show", side_effect=committed):
            gate._require_current_contract_bytes(
                gate.REPO_ROOT, "git", "a" * 40
            )
        with mock.patch.object(gate, "_git_show", return_value=b"different"):
            with self.assertRaisesRegex(gate.GateError, "current .*candidate ref"):
                gate._require_current_contract_bytes(
                    gate.REPO_ROOT, "git", "a" * 40
                )

        for drift_path in (gate.HARNESS_PATH, gate.WINDOWS_JOB_PATH):
            def drifted(
                _repo: Path, _git: str, _commit: str, path: str,
                *, target: str = drift_path,
            ) -> bytes:
                if path == target:
                    return b"drifted helper"
                return (gate.REPO_ROOT / path).read_bytes()

            with self.subTest(path=drift_path), mock.patch.object(
                gate, "_git_show", side_effect=drifted
            ), self.assertRaisesRegex(gate.GateError, "current .*candidate ref"):
                gate._require_current_contract_bytes(
                    gate.REPO_ROOT, "git", "a" * 40
                )

    def test_link_command_and_claimed_lld_provenance_are_consistent(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            stage = gate._stage_layout(root)
            lld = (root / "tools" / "lld-link.exe").resolve()
            tools = {
                "clang": {"path": str((root / "tools" / "clang.exe").resolve())},
                "clangxx": {"path": str((root / "tools" / "clang++.exe").resolve())},
                "lld_link": {"path": str(lld)},
            }
            link = gate._expected_build_commands(stage, tools)[-1][1]
            self.assertIn(f"-B{lld.parent}", link)
            self.assertIn("-fuse-ld=lld", link)
            selected_without_suffix = str(lld.with_suffix(""))
            completed = mock.Mock(
                returncode=0,
                stdout=b"",
                stderr=(
                    f"{json.dumps(selected_without_suffix)} \"-out:vorton.exe\"\n"
                ).encode("utf-8"),
            )
            with mock.patch.object(gate.subprocess, "run", return_value=completed):
                binding = gate._probe_linker_binding(
                    link,
                    Path(stage["source"]),
                    lld,
                    {},
                    root=root,
                    stem="linker-probe",
                )
            self.assertEqual(binding["claimed_path"], str(lld))
            self.assertEqual(binding["selected_path"], str(lld))
            self.assertEqual(binding["probe_argv"], [link[0], "-###", *link[1:]])
            self.assertEqual(
                gate._sidecar(root, binding["stdout"], "probe.stdout").read_bytes(),
                b"",
            )
            self.assertEqual(
                gate._sidecar(root, binding["stderr"], "probe.stderr").read_bytes(),
                completed.stderr,
            )

            expected = gate._expected_linker_binding(
                link, Path(stage["source"]), lld
            )
            gate._verify_linker_binding(root, binding, expected, set(), "candidate")
            forged = copy.deepcopy(binding)
            forged_stderr = root / "raw" / "forged-linker-probe.stderr"
            forged_stderr.write_bytes(
                f'{json.dumps(str(root / "other-lld-link"))} "-out:vorton.exe"\n'.encode(
                    "utf-8"
                )
            )
            forged["stderr"] = gate._relative_file_record(forged_stderr, root)
            with self.assertRaisesRegex(gate.GateError, "raw linker probe"):
                gate._verify_linker_binding(
                    root, forged, expected, set(), "candidate"
                )

    def test_archive_member_preflight_rejects_windows_crlf_conversion(self) -> None:
        blob = b"line\n"
        inputs = {
            path: blob
            for path in (
                gate.ANCHOR_PATH,
                gate.RUNTIME_PATH,
                gate.FIXTURE_PATH,
                gate.GATE_PATH,
                gate.SCHEMA_PATH,
                gate.HARNESS_PATH,
                gate.WINDOWS_JOB_PATH,
                *gate.STD_PATHS,
            )
        }
        with mock.patch.object(gate, "_git_show", return_value=blob):
            gate._require_archive_member_identity(
                gate.REPO_ROOT, "git", "a" * 40, "candidate", inputs
            )
            for path in (
                gate.GATE_PATH,
                gate.SCHEMA_PATH,
                gate.HARNESS_PATH,
                gate.WINDOWS_JOB_PATH,
            ):
                changed = dict(inputs)
                changed[path] = b"line\r\n"
                with self.subTest(path=path), self.assertRaisesRegex(
                    gate.GateError, "archive member bytes differ from Git object"
                ):
                    gate._require_archive_member_identity(
                        gate.REPO_ROOT, "git", "a" * 40, "candidate", changed
                    )
            del inputs[gate.STD_PATHS[0]]
            with self.assertRaisesRegex(
                gate.GateError, "archive member bytes differ from Git object"
            ):
                gate._require_archive_member_identity(
                    gate.REPO_ROOT, "git", "a" * 40, "candidate", inputs
                )

    def test_neutral_std_layout_contains_only_verified_prelude_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            stage = gate._stage_layout(root)
            self.assertEqual(Path(stage["std"]), root / "stage" / "std")
            self.assertEqual(Path(stage["cwd"]), root / "stage" / "cwd")
            inputs = {
                path: f"source:{path}\n".encode("utf-8") for path in gate.STD_PATHS
            }
            gate._write_neutral_std(stage, inputs)
            actual = sorted(
                path.relative_to(Path(stage["std"])).as_posix()
                for path in Path(stage["std"]).rglob("*")
                if path.is_file()
            )
            self.assertEqual(actual, sorted(Path(path).name for path in gate.STD_PATHS))
            for path in gate.STD_PATHS:
                self.assertEqual(
                    (Path(stage["std"]) / Path(path).name).read_bytes(),
                    inputs[path],
                )

    def test_pair_count_and_order_tampering_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            stage = gate._stage_layout(root)
            warmups, pairs = self._rows(root, stage, 4, gate.MEASURED_PAIRS)
            with self.assertRaisesRegex(gate.GateError, "pair count drifted"):
                gate._verify_rows(root, stage, self._subjects(), warmups, pairs)

            warmups, pairs = self._rows(
                root, stage, gate.WARMUP_PAIRS, gate.MEASURED_PAIRS
            )
            warmups[0]["order"] = ["candidate", "base"]
            with self.assertRaisesRegex(gate.GateError, "pair/order/index drifted"):
                gate._verify_rows(root, stage, self._subjects(), warmups, pairs)

    def test_binary_and_sidecar_hash_tampering_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            stage = gate._stage_layout(root)
            warmups, pairs = self._rows(root, stage, 1, 1, write_streams=True)
            with (
                mock.patch.object(gate, "WARMUP_PAIRS", 1),
                mock.patch.object(gate, "MEASURED_PAIRS", 1),
            ):
                gate._verify_rows(root, stage, self._subjects(), warmups, pairs)

                changed = copy.deepcopy(warmups)
                changed[0]["invocations"][0]["binary_raw_sha256"] = "c" * 64
                with self.assertRaisesRegex(gate.GateError, "raw contract drifted"):
                    gate._verify_rows(root, stage, self._subjects(), changed, pairs)

                changed = copy.deepcopy(warmups)
                changed[0]["invocations"][0]["stdout"]["sha256"] = "d" * 64
                with self.assertRaisesRegex(gate.GateError, "hash/length differs"):
                    gate._verify_rows(root, stage, self._subjects(), changed, pairs)

    def test_stored_summary_and_pass_are_never_trusted(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            stage = gate._stage_layout(root)
            _warmups, passing = self._rows(
                root, stage, 0, gate.MEASURED_PAIRS, candidate_wall_ns=101_000_000
            )
            passing_summary = gate._recompute_summary(passing)
            gate._verify_claimed_result(passing, passing_summary, "PASS")

            forged_summary = copy.deepcopy(passing_summary)
            forged_summary["candidate_over_base_ratio"]["median"] = 0.1
            with self.assertRaisesRegex(gate.GateError, "stored summary"):
                gate._verify_claimed_result(passing, forged_summary, "PASS")

            _warmups, failing = self._rows(
                root, stage, 0, gate.MEASURED_PAIRS, candidate_wall_ns=105_000_000
            )
            failing_summary = gate._recompute_summary(failing)
            self.assertFalse(failing_summary["passed"])
            with self.assertRaisesRegex(gate.GateError, "stored PASS/FAIL"):
                gate._verify_claimed_result(failing, failing_summary, "PASS")

    def test_threshold_tampering_is_rejected(self) -> None:
        contract = gate._contract()
        gate._require_contract(contract)
        contract["median_ratio_max"] = 1.20
        with self.assertRaisesRegex(gate.GateError, "contract drifted"):
            gate._require_contract(contract)


if __name__ == "__main__":
    unittest.main()
