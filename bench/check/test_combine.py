from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import combine
import run as harness


def phase_errors(classified: harness.PhaseValidation) -> list[str]:
    return [*classified.hard_errors, *classified.eligibility_errors]


class StrictCombineTests(unittest.TestCase):
    def setUp(self) -> None:
        self._canonical_manifest_sha = harness.CANONICAL_MANIFEST_SHA256

    def tearDown(self) -> None:
        harness.CANONICAL_MANIFEST_SHA256 = self._canonical_manifest_sha

    def _compiler_rows(self) -> list[dict]:
        durations = {
            "input_entry_load": 10,
            "entry_parse": 20,
            "project_module_load_parse": 0,
            "type_effect_check_lower": 30,
            "resource_plan_verify": 0,
            "command_total": 100,
        }
        entry = str((harness.REPO_ROOT / "tests" / "cases" / "hello.vorton").resolve())
        return [
            {
                "schema": harness.COMPILER_PHASE_SCHEMA,
                "schema_version": 1,
                "lane": "fixture_cold",
                "phase": phase,
                "duration_ns": durations[phase],
                "unit": "ns",
                "compiler_identity": "sha256:" + "d" * 64,
                "source_identity": "git:" + "a" * 40,
                "entry_file": entry,
                "executed": phase not in {
                    "project_module_load_parse",
                    "resource_plan_verify",
                },
                "complete": True,
                "command_success": True,
            }
            for phase in harness.COMPILER_PHASE_ORDER
        ]

    def _manifest(self, *, runner: bool = False) -> dict:
        if runner:
            stdout = (
                "[PASS] parity: fixture\n"
                "Exit code: 0 (all 1 tests passed)\n"
            )
            cases_sha = harness.runner_cases_contract(stdout)["sha256"]
            return {
                "schema": harness.MANIFEST_SCHEMA,
                "description": "runner combine fixture",
                "fingerprint_flags": {
                    "compiler": ["-O3"],
                    "runtime": ["-O3"],
                    "runner_runtime": ["-O2"],
                    "link": [
                        "-flto=thin",
                        "-fuse-ld=lld",
                        (
                            "-Wl,/lldltocachepolicy:cache_size_bytes=1073741824:"
                            "cache_size_files=4096:prune_after=168h"
                        ),
                    ],
                },
                "lanes": [
                    {
                        "case_id": "fixture",
                        "description": "runner fixture",
                        "policy": "full_gate",
                        "cache_states": ["cold", "warm"],
                        "argv": [
                            "{python}",
                            "{repo}/tests/run_tests.py",
                            "--suite",
                            "parity",
                            "--filter",
                            "fixture",
                            f"--phase-timing={harness.RUNNER_TRACE_PATH}",
                        ],
                        "cwd": "{repo}",
                        "timeout_seconds": 10,
                        "expected_exit_codes": [0],
                        "requires": ["tool:python"],
                        "runner_summary": {
                            "schema": harness.RUNNER_SUMMARY_CONTRACT_SCHEMA,
                            "expected_total": 1,
                            "expected_status_counts": {
                                "pass": 1,
                                "fail": 0,
                                "skip": 0,
                            },
                            "expected_suite_counts": {
                                "parity": {"pass": 1, "fail": 0, "skip": 0}
                            },
                            "expected_cases_sha256": cases_sha,
                            "skip_policy": "exact",
                            "fail_policy": "zero",
                            "reported_exit_policy": "required_match_raw",
                        },
                        "compiler_phase_timing": False,
                        "runner_phase_timing": True,
                        "bootstrap_phase_timing": False,
                        "artifacts": [],
                        "phase_trace_paths": [harness.RUNNER_TRACE_PATH],
                    }
                ],
            }
        return {
            "schema": harness.MANIFEST_SCHEMA,
            "description": "combine fixture",
            "fingerprint_flags": {
                "compiler": ["-O3"],
                "runtime": ["-O3"],
                "runner_runtime": ["-O2"],
                "link": [
                    "-flto=thin",
                    "-fuse-ld=lld",
                    (
                        "-Wl,/lldltocachepolicy:cache_size_bytes=1073741824:"
                        "cache_size_files=4096:prune_after=168h"
                    ),
                ],
            },
            "lanes": [
                {
                    "case_id": "fixture",
                    "description": "fixture",
                    "policy": "full_gate",
                    "cache_states": ["cold", "warm"],
                    "argv": ["{vorton}", "check", "{repo}/fixture.vorton"],
                    "cwd": "{repo}",
                    "timeout_seconds": 10,
                    "expected_exit_codes": [0],
                    "requires": ["tool:vorton"],
                    "runner_summary": None,
                    "compiler_phase_timing": False,
                    "runner_phase_timing": False,
                    "bootstrap_phase_timing": False,
                    "artifacts": ["{sample_dir}/artifact.bin"],
                    "phase_trace_paths": [],
                }
            ],
        }

    def _schema(self, _keys: set[str]) -> dict:
        return harness._load_json(harness.DEFAULT_RESULT_SCHEMA)

    def _seed_receipt(
        self, root: Path, source_sha: str, manifest: dict
    ) -> dict:
        cache = (root / "vorton-lang-thinlto-cache").resolve()
        cache.mkdir(exist_ok=True)
        seed_file = cache / "seed.bin"
        if not seed_file.exists():
            seed_file.write_bytes(b"seed")
        tool_names = {
            "python": "python.exe",
            "clang": "clang.exe",
            "clangxx": "clang++.exe",
            "lld_link": "lld-link.exe",
        }
        tools = {}
        for name, filename in tool_names.items():
            path = (root / "tools" / filename).resolve()
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(f"{name}-tool".encode("utf-8"))
            tools[name] = {
                "path": str(path),
                "version": "fixture",
                "sha256": harness._sha256_file(path),
            }
        tool_paths = {name: record["path"] for name, record in tools.items()}
        _receipt_path, output = harness._warm_cache_paths(cache)
        output.mkdir(exist_ok=True)
        for name in ("compiler_object", "runtime_object", "vorton"):
            (output / harness.WARM_CACHE_BUILD_FILES[name]).write_bytes(
                name.encode("utf-8")
            )
        commands = harness._expected_warm_cache_build_commands(
            manifest, tool_paths, cache
        )
        trace = output / harness.WARM_CACHE_BUILD_FILES["phase_trace"]
        trace.write_text(
            "".join(
                harness._json_line(
                    {
                        "schema": harness.BOOTSTRAP_PHASE_SCHEMA,
                        "phase": phase,
                        "argv": argv,
                        "wall_ns": 1,
                        "exit_code": 0,
                    }
                )
                + "\n"
                for phase, argv in commands
            ),
            encoding="utf-8",
            newline="\n",
        )
        probe_stdout = output / harness.WARM_CACHE_BUILD_FILES[
            "linker_probe_stdout"
        ]
        probe_stderr = output / harness.WARM_CACHE_BUILD_FILES[
            "linker_probe_stderr"
        ]
        probe_stdout.write_bytes(b"")
        lld = Path(tools["lld_link"]["path"])
        probe_stderr.write_bytes(
            f'{json.dumps(str(lld.with_suffix("")))} "-out:vorton.exe"\n'.encode(
                "utf-8"
            )
        )
        link_argv = commands[-1][1]
        binding = {
            "schema": harness.LINKER_BINDING_SCHEMA,
            "probe_argv": [link_argv[0], "-###", *link_argv[1:]],
            "cwd": str(harness.REPO_ROOT.resolve()),
            "claimed_path": str(lld.resolve()),
            "selected_path": str(lld.resolve()),
            "exit_code": 0,
            "stdout": harness._file_record(probe_stdout),
            "stderr": harness._file_record(probe_stderr),
        }
        harness._json_dump(
            output / harness.WARM_CACHE_BUILD_FILES["linker_binding"], binding
        )
        build_output = {
            name: harness._file_record(output / filename)
            for name, filename in harness.WARM_CACHE_BUILD_FILES.items()
        }
        return {
            "schema": harness.WARM_CACHE_RECEIPT_SCHEMA,
            "recipe_version": 2,
            "source": {
                "git_sha": source_sha,
                "git_dirty": False,
                "dist_c": {"path": str((root / "dist-c").resolve()), "sha256": "b" * 64, "bytes": 1},
                "runtime": {"path": str((root / "runtime").resolve()), "sha256": "c" * 64, "bytes": 1},
                "bootstrap": {"path": str((root / "bootstrap").resolve()), "sha256": "e" * 64, "bytes": 1},
            },
            "tools": tools,
            "flags": {
                name: manifest["fingerprint_flags"][name]
                for name in ("compiler", "runtime", "link")
            },
            "cache_path": str(cache),
            "seed_invocation": harness._warm_cache_seed_recipe_from_paths(
                cache, tool_paths
            ),
            "outcome": {
                "exit_code": 0,
                "stdout": {"sha256": "4" * 64, "bytes": 0},
                "stderr": {"sha256": "5" * 64, "bytes": 0},
            },
            "cache_inventory": harness._cache_inventory(cache),
            "build_output": build_output,
        }

    def _record(
        self,
        *,
        run_id: str,
        case_id: str,
        state: str,
        index: int,
        source_sha: str,
        manifest_sha: str,
        run_dir: Path,
        runner: bool = False,
    ) -> dict:
        sample_id = f"{case_id}-{index:03d}-{index:08x}"
        sample_dir = (run_dir / "samples" / case_id / sample_id).resolve()
        sample_dir.mkdir(parents=True)
        stdout_path = sample_dir / "stdout.txt"
        stderr_path = sample_dir / "stderr.txt"
        artifact_path = sample_dir / "artifact.bin"
        stdout_path.write_text(
            (
                "[PASS] parity: fixture\n"
                "Exit code: 0 (all 1 tests passed)\n"
            )
            if runner
            else "",
            encoding="utf-8",
        )
        stderr_path.write_bytes(b"")
        if not runner:
            artifact_path.write_bytes(b"artifact")
        if runner:
            trace_path = sample_dir / "runner-phase-timing.jsonl"
            rows = [
                {
                    "schema": harness.RUNNER_PHASE_SCHEMA,
                    "version": 1,
                    "sequence": 1,
                    "suite": "parity",
                    "case": None,
                    "stage": "orchestration_residual",
                    "duration_ns": 60,
                    "executed": True,
                    "complete": True,
                    "outcome": "completed",
                    "exit_code": None,
                    "command_category": None,
                },
                {
                    "schema": harness.RUNNER_PHASE_SCHEMA,
                    "version": 1,
                    "sequence": 2,
                    "suite": "parity",
                    "case": None,
                    "stage": "suite_total",
                    "duration_ns": 60,
                    "executed": True,
                    "complete": True,
                    "outcome": "completed",
                    "exit_code": None,
                    "command_category": None,
                },
                {
                    "schema": harness.RUNNER_PHASE_SCHEMA,
                    "version": 1,
                    "sequence": 3,
                    "suite": None,
                    "case": "runner",
                    "stage": "orchestration_residual",
                    "duration_ns": 10,
                    "executed": True,
                    "complete": True,
                    "outcome": "success",
                    "exit_code": 0,
                    "command_category": None,
                },
                {
                    "schema": harness.RUNNER_PHASE_SCHEMA,
                    "version": 1,
                    "sequence": 4,
                    "suite": None,
                    "case": "runner",
                    "stage": "runner_total",
                    "duration_ns": 70,
                    "executed": True,
                    "complete": True,
                    "outcome": "success",
                    "exit_code": 0,
                    "command_category": None,
                },
            ]
            trace_path.write_text(
                "".join(harness._json_line(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            argv = [
                str((run_dir.parent / "tools" / "python.exe").resolve()),
                f"{harness.REPO_ROOT}/tests/run_tests.py",
                "--suite",
                "parity",
                "--filter",
                "fixture",
                f"--phase-timing={sample_dir}/runner-phase-timing.jsonl",
            ]
            runner_summary = harness._runner_summary(stdout_path)
            artifacts = []
            phase_traces = harness._phase_trace_records([trace_path])
        else:
            argv = [
                str(
                    (
                        run_dir.parent
                        / harness.WARM_CACHE_OUTPUT_NAME
                        / harness.WARM_CACHE_BUILD_FILES["vorton"]
                    ).resolve()
                ),
                "check",
                f"{harness.REPO_ROOT}/fixture.vorton",
            ]
            runner_summary = None
            artifacts = harness._artifact_records([artifact_path])
            phase_traces = []
        return {
            "schema": harness.RESULT_SCHEMA,
            "run_id": run_id,
            "sample_id": sample_id,
            "sample_dir": str(sample_dir),
            "case_id": case_id,
            "index": index,
            "included": True,
            "source_sha": source_sha,
            "manifest_sha": manifest_sha,
            "argv": argv,
            "cwd": str(harness.REPO_ROOT.resolve()),
            "cache": {
                "thinlto_cache": state,
                "output": "fresh",
                "os_file_cache": "uncontrolled",
            },
            "wall_ns": 100 + index,
            "cpu_user_ns": 10,
            "cpu_kernel_ns": 5,
            "peak_root_rss_bytes": 1000,
            "sampled_peak_tree_rss_bytes": 1000,
            "max_worker_peak_rss_bytes": None,
            "peak_job_commit_bytes": 2000,
            "root_pid": 1,
            "rss_poll_ms": harness.RSS_POLL_MS,
            "rss_samples_observed": 1,
            "rss_covered_ns": 100 + index,
            "rss_coverage_ratio": 1.0,
            "rss_observed_process_count": 1,
            "rss_job_total_processes": 1,
            "rss_complete": True,
            "process_count": {
                "total": 1,
                "active_at_query": 0,
                "terminated": 1,
            },
            "job_io": {
                "read_operations": 0,
                "write_operations": 0,
                "other_operations": 0,
                "read_bytes": 0,
                "write_bytes": 0,
                "other_bytes": 0,
            },
            "timed_out": False,
            "measurement_errors": [],
            "runner_runtime": {
                "mode": "not_applicable",
                "isolated": False,
                "root_path": None,
                "source_sha256": None,
                "flags": [],
                "original_exists": False,
                "original_sha256": None,
                "pre_exists": False,
                "pre_sha256": None,
                "post_exists": False,
                "post_sha256": None,
                "restored": True,
                "backup_path": None,
                "backup_exists_after": False,
                "staging_path": None,
                "staging_exists_after": False,
                "errors": [],
            },
            "exit": {"code": 0, "expected": True},
            "stdout": harness._file_record(stdout_path),
            "stderr": harness._file_record(stderr_path),
            "runner_summary": runner_summary,
            "artifacts": artifacts,
            "phase_traces": phase_traces,
            "invocation_error": None,
            "invalid_reason": None,
        }

    def _write_run(
        self,
        root: Path,
        *,
        state: str,
        run_id: str,
        source_sha: str = "a" * 40,
        runner: bool = False,
    ) -> Path:
        run_dir = root / run_id
        run_dir.mkdir()
        manifest = self._manifest(runner=runner)
        manifest_path = run_dir / "manifest.snapshot.json"
        harness._json_dump(manifest_path, manifest)
        harness.CANONICAL_MANIFEST_SHA256 = harness._sha256_file(manifest_path)
        manifest_sha = harness._sha256_file(manifest_path)
        case_id = f"fixture_{state}"
        records = [
            self._record(
                run_id=run_id,
                case_id=case_id,
                state=state,
                index=index,
                source_sha=source_sha,
                manifest_sha=manifest_sha,
                run_dir=run_dir,
                runner=runner,
            )
            for index in range(3)
        ]
        schema = self._schema(set(records[0]))
        harness._json_dump(run_dir / "result.schema.json", schema)
        samples_path = run_dir / "samples.jsonl"
        samples_path.write_text(
            "".join(harness._json_line(record) + "\n" for record in records),
            encoding="utf-8",
        )
        lane_summary = harness.summarize_lane(
            {"case_id": case_id, "policy": "full_gate"}, records, 3
        )
        summary = {
            "schema": harness.SUMMARY_SCHEMA,
            "run_id": run_id,
            "source_sha": source_sha,
            "manifest_sha": manifest_sha,
            "samples_jsonl": harness._file_record(samples_path),
            "lanes": [lane_summary],
            "complete": True,
        }
        harness._json_dump(run_dir / "summary.json", summary)
        environment = {
            "schema": harness.ENVIRONMENT_SCHEMA,
            "run_id": run_id,
            "source_sha": source_sha,
            "git_dirty": False,
            "manifest_sha": manifest_sha,
            "dist_c_sha256": "b" * 64,
            "runtime_sha256": "c" * 64,
            "tools": {
                "vorton": {
                    "path": self._seed_receipt(root, source_sha, manifest)[
                        "build_output"
                    ]["vorton"]["path"],
                    "version": "v",
                    "sha256": self._seed_receipt(root, source_sha, manifest)[
                        "build_output"
                    ]["vorton"]["sha256"],
                },
                **self._seed_receipt(root, source_sha, manifest)["tools"],
            },
            "flags": manifest["fingerprint_flags"],
            "cache_state": state,
            "thinlto_cache_path": str(
                (root / "vorton-lang-thinlto-cache").resolve()
            ),
            "thinlto_cache_inventory": self._seed_receipt(
                root, source_sha, manifest
            )["cache_inventory"],
            "os": {"system": "Windows", "release": "fixture", "version": "1", "machine": "AMD64"},
            "cpu": {"model": "fixture cpu", "logical_cores": 8},
            "memory_bytes": 16 * 1024 * 1024 * 1024,
            "power": {
                "active_scheme": "fixture scheme",
                "ac_line_status": 1,
                "battery_flag": 0,
                "battery_life_percent": 50,
            },
        }
        receipt = self._seed_receipt(root, source_sha, manifest)
        receipt_path = run_dir / "warm-cache-seed-receipt.json"
        harness._json_dump(receipt_path, receipt)
        environment["warm_cache_seed"] = {
            "identity": receipt,
            "receipt": harness._file_record(receipt_path),
        }
        harness._json_dump(run_dir / "environment.json", environment)
        return run_dir

    def _rewrite_samples_and_summary(
        self, run_dir: Path, mutate
    ) -> None:
        samples_path = run_dir / "samples.jsonl"
        records = [
            json.loads(line)
            for line in samples_path.read_text(encoding="utf-8").splitlines()
        ]
        mutate(records)
        samples_path.write_text(
            "".join(harness._json_line(record) + "\n" for record in records),
            encoding="utf-8",
        )
        summary_path = run_dir / "summary.json"
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        lane_summary = summary["lanes"][0]
        summary["lanes"] = [
            harness.summarize_lane(
                {
                    "case_id": lane_summary["case_id"],
                    "policy": lane_summary["policy"],
                },
                records,
                lane_summary["target_valid_samples"],
            )
        ]
        summary["samples_jsonl"] = harness._file_record(samples_path)
        harness._json_dump(summary_path, summary)

    def _rewrite_retained_seed(self, run_dir: Path, mutate) -> None:
        environment_path = run_dir / "environment.json"
        environment = json.loads(environment_path.read_text(encoding="utf-8"))
        receipt = environment["warm_cache_seed"]["identity"]
        mutate(receipt)
        receipt_path = run_dir / "warm-cache-seed-receipt.json"
        harness._json_dump(receipt_path, receipt)
        environment["warm_cache_seed"] = {
            "identity": receipt,
            "receipt": harness._file_record(receipt_path),
        }
        harness._json_dump(environment_path, environment)

    def test_combines_complete_cold_and_warm_batches(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            warm = self._write_run(root, state="warm", run_id="warm-run")
            output = root / "combined"
            summary = combine.combine_runs([cold, warm], output)
            self.assertTrue(summary["complete"])
            self.assertEqual(summary["coverage"]["actual_lane_count"], 2)
            self.assertEqual(summary["cache_states"]["cold"]["included_samples"], 3)
            self.assertEqual(summary["cache_states"]["warm"]["included_samples"], 3)
            self.assertEqual(
                len((output / "combined-samples.jsonl").read_text().splitlines()), 6
            )
            self.assertTrue((output / "combined-summary.json").is_file())

    def test_combines_and_replays_runner_phase_summaries_per_lane(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(
                root, state="cold", run_id="runner-cold", runner=True
            )
            warm = self._write_run(
                root, state="warm", run_id="runner-warm", runner=True
            )
            summary = combine.combine_runs(
                [cold, warm], root / "runner-combined"
            )
            self.assertTrue(summary["complete"])
            lanes = {lane["case_id"]: lane for lane in summary["lanes"]}
            self.assertEqual(set(lanes), {"fixture_cold", "fixture_warm"})
            for case_id, lane in lanes.items():
                with self.subTest(case_id=case_id):
                    timing = lane["runner_phase_timing"]
                    self.assertEqual(timing["sample_count"], 3)
                    self.assertEqual(timing["runner_total_ns"]["median"], 70)
                    self.assertEqual(
                        timing["accounting"]["runner"]["balance_ns"]["median"],
                        0,
                    )

    def test_combine_replay_rejects_early_runner_summary_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            run_dir = self._write_run(
                root, state="cold", run_id="runner-tampered", runner=True
            )
            samples_path = run_dir / "samples.jsonl"
            records = [
                json.loads(line)
                for line in samples_path.read_text(encoding="utf-8").splitlines()
            ]
            record = records[0]
            trace_path = Path(record["phase_traces"][0]["path"])
            rows = [
                json.loads(line)
                for line in trace_path.read_text(encoding="utf-8").splitlines()
            ]
            early_pair = [dict(rows[-2]), dict(rows[-1])]
            for row in early_pair:
                row["duration_ns"] = 0
            rows[0:0] = early_pair
            for sequence, row in enumerate(rows, 1):
                row["sequence"] = sequence
            trace_path.write_text(
                "".join(harness._json_line(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            record["phase_traces"] = harness._phase_trace_records([trace_path])
            samples_path.write_text(
                "".join(harness._json_line(item) + "\n" for item in records),
                encoding="utf-8",
            )
            summary_path = run_dir / "summary.json"
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            summary["samples_jsonl"] = harness._file_record(samples_path)
            harness._json_dump(summary_path, summary)
            with self.assertRaisesRegex(harness.HarnessError, "unique terminal"):
                combine.combine_runs([run_dir], root / "replay-output")

    def test_unpaired_descriptive_control_reports_median_mad_and_p95_delta(self) -> None:
        def lane(wall: dict) -> dict:
            return {"summary": {"metrics": {"wall_ns": wall}}}

        timed = {"median": 110, "mad": 4, "empirical_p95": 140}
        control = {"median": 100, "mad": 3, "empirical_p95": 125}
        origins = {
            f"tiny_hello_check_{state}": lane(timed)
            for state in ("cold", "warm")
        }
        origins.update(
            {
                f"tiny_hello_check_no_phase_{state}": lane(control)
                for state in ("cold", "warm")
            }
        )
        comparison = combine._unpaired_descriptive_control(origins)
        self.assertEqual(
            comparison["cold"]["delta_ns"],
            {"median": 10, "mad": 1, "empirical_p95": 15},
        )

    def test_revalidates_wrapped_compiler_phase_trace(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            sample_dir = Path(temp).resolve()
            path = sample_dir / "trace.jsonl"
            rows = self._compiler_rows()
            wrappers = [
                {
                    "path": str(path),
                    "line": index,
                    "value": row,
                    "read_error": None,
                }
                for index, row in enumerate(rows, 1)
            ]
            lane = {
                "case_id": "fixture_cold",
                "compiler_phase_timing": True,
                "expected_executed_phases": [
                    "input_entry_load",
                    "entry_parse",
                    "type_effect_check_lower",
                    "command_total",
                ],
                "phase_trace_paths": ["{sample_dir}/trace.jsonl"],
            }
            environment = {
                "source_sha": "a" * 40,
                "tools": {"vorton": {"sha256": "d" * 64}},
            }
            errors = phase_errors(harness._classify_phase_trace_records(
                wrappers,
                paths=[path],
                sample_dir=sample_dir,
                lane=lane,
                environment=environment,
                expected_entry_file=str(
                    (harness.REPO_ROOT / "tests" / "cases" / "hello.vorton").resolve()
                ),
                exit_code=0,
                wall_ns=150,
            ))
            self.assertEqual(errors, [])
            rows[0]["compiler_identity"] = "sha256:" + "e" * 64
            errors = phase_errors(harness._classify_phase_trace_records(
                wrappers,
                paths=[path],
                sample_dir=sample_dir,
                lane=lane,
                environment=environment,
                expected_entry_file=str(
                    (harness.REPO_ROOT / "tests" / "cases" / "hello.vorton").resolve()
                ),
                exit_code=0,
                wall_ns=150,
            ))
            self.assertTrue(any("compiler identity mismatch" in error for error in errors))

    def test_rejects_lane_records_after_target_is_reached(self) -> None:
        records = [
            {"index": index, "included": included, "invalid_reason": reason}
            for index, included, reason in (
                (0, True, None),
                (1, True, None),
                (2, True, None),
                (3, False, "measurement_errors: late invalid"),
            )
        ]
        with self.assertRaisesRegex(harness.HarnessError, "continued after"):
            combine._validate_lane_schedule("full_gate", records, 3, "fixture_cold")

    def test_rejects_incomplete_run(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            summary_path = cold / "summary.json"
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            summary["complete"] = False
            harness._json_dump(summary_path, summary)
            with self.assertRaisesRegex(harness.HarnessError, "incomplete"):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_structurally_valid_reduced_or_byte_drifted_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            harness.CANONICAL_MANIFEST_SHA256 = self._canonical_manifest_sha
            with self.assertRaisesRegex(harness.HarnessError, "formal manifest bytes"):
                combine.combine_runs([cold], root / "combined-reduced")

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            manifest_path = cold / "manifest.snapshot.json"
            manifest_path.write_bytes(manifest_path.read_bytes() + b" ")
            with self.assertRaisesRegex(harness.HarnessError, "formal manifest bytes"):
                combine.combine_runs([cold], root / "combined-byte-drift")

    def test_rejects_old_or_lax_schema_before_reading_raw_samples(self) -> None:
        mutations = {
            "old_v1": lambda schema: schema.update(
                {"$id": "vorton.check-benchmark.invocation.v1"}
            ),
            "same_id_lax": lambda schema: schema["properties"]["runner_summary"][
                "properties"
            ].__setitem__("suite_counts", {"type": "object"}),
        }
        for name, mutate in mutations.items():
            with self.subTest(case=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                cold = self._write_run(root, state="cold", run_id="cold-run")
                schema_path = cold / "result.schema.json"
                schema = json.loads(schema_path.read_text(encoding="utf-8"))
                mutate(schema)
                harness._json_dump(schema_path, schema)
                (cold / "samples.jsonl").write_text("not-json\n", encoding="utf-8")
                expected = r"\$id" if name == "old_v1" else "canonical invocation.v3"
                with self.assertRaisesRegex(harness.HarnessError, expected):
                    combine.combine_runs([cold], root / "combined")

    def test_duplicate_json_keys_fail_in_metadata_and_nested_samples(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            environment_path = cold / "environment.json"
            environment_path.write_text(
                '{"schema":"first","nested":{"x":1,"x":2}}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(harness.DuplicateJsonKeyError, "duplicate JSON key"):
                combine.combine_runs([cold], root / "combined")

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            samples_path = cold / "samples.jsonl"
            lines = samples_path.read_text(encoding="utf-8").splitlines()
            lines[0] = lines[0].replace(
                '"cache": {', '"cache": {"output":"fresh",', 1
            )
            samples_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            summary_path = cold / "summary.json"
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            summary["samples_jsonl"] = harness._file_record(samples_path)
            harness._json_dump(summary_path, summary)
            with self.assertRaisesRegex(harness.DuplicateJsonKeyError, "duplicate JSON key"):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_identity_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            warm = self._write_run(
                root, state="warm", run_id="warm-run", source_sha="e" * 40
            )
            with self.assertRaisesRegex(harness.HarnessError, "identity/toolchain drift"):
                combine.combine_runs([cold, warm], root / "combined")

    def test_rejects_wrong_seed_across_batches_and_retained_receipt_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            warm = self._write_run(root, state="warm", run_id="warm-run")
            environment_path = warm / "environment.json"
            environment = json.loads(environment_path.read_text(encoding="utf-8"))
            receipt = environment["warm_cache_seed"]["identity"]
            receipt["outcome"]["stdout"]["sha256"] = "9" * 64
            receipt_path = warm / "warm-cache-seed-receipt.json"
            harness._json_dump(receipt_path, receipt)
            environment["warm_cache_seed"]["receipt"] = harness._file_record(receipt_path)
            harness._json_dump(environment_path, environment)
            with self.assertRaisesRegex(harness.HarnessError, "identity/toolchain drift"):
                combine.combine_runs([cold, warm], root / "combined")

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            receipt_path = cold / "warm-cache-seed-receipt.json"
            receipt_path.write_bytes(receipt_path.read_bytes() + b" ")
            with self.assertRaisesRegex(harness.HarnessError, "receipt file provenance"):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_self_consistent_arbitrary_linker_probe_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")

            def replace_probe(receipt: dict) -> None:
                stderr = Path(
                    receipt["build_output"]["linker_probe_stderr"]["path"]
                )
                stderr.write_bytes(b"arbitrary non-parseable linker output\n")
                binding_path = Path(
                    receipt["build_output"]["linker_binding"]["path"]
                )
                binding = json.loads(binding_path.read_text(encoding="utf-8"))
                binding["stderr"] = harness._file_record(stderr)
                harness._json_dump(binding_path, binding)
                receipt["build_output"]["linker_probe_stderr"] = (
                    harness._file_record(stderr)
                )
                receipt["build_output"]["linker_binding"] = harness._file_record(
                    binding_path
                )

            self._rewrite_retained_seed(cold, replace_probe)
            with self.assertRaisesRegex(harness.HarnessError, "raw linker probe"):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_missing_retained_linker_probe_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            environment = json.loads(
                (cold / "environment.json").read_text(encoding="utf-8")
            )
            stderr = Path(
                environment["warm_cache_seed"]["identity"]["build_output"][
                    "linker_probe_stderr"
                ]["path"]
            )
            stderr.unlink()
            with self.assertRaisesRegex(
                harness.HarnessError, "missing retained warm-cache seed"
            ):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_linker_binding_sidecar_path_and_hash_drift(self) -> None:
        for drift in ("path", "hash"):
            with self.subTest(drift=drift), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                cold = self._write_run(root, state="cold", run_id="cold-run")

                def mutate_binding(receipt: dict) -> None:
                    binding_path = Path(
                        receipt["build_output"]["linker_binding"]["path"]
                    )
                    binding = json.loads(binding_path.read_text(encoding="utf-8"))
                    if drift == "path":
                        original = Path(binding["stderr"]["path"])
                        forged = original.with_name("forged-linker-probe.stderr.txt")
                        forged.write_bytes(original.read_bytes())
                        binding["stderr"] = harness._file_record(forged)
                    else:
                        binding["stderr"]["sha256"] = "0" * 64
                    harness._json_dump(binding_path, binding)
                    receipt["build_output"]["linker_binding"] = (
                        harness._file_record(binding_path)
                    )

                self._rewrite_retained_seed(cold, mutate_binding)
                with self.assertRaisesRegex(
                    harness.HarnessError, "linker binding drifted"
                ):
                    combine.combine_runs([cold], root / "combined")

    def test_rejects_retained_seed_tool_byte_and_invocation_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            environment = json.loads(
                (cold / "environment.json").read_text(encoding="utf-8")
            )
            lld = Path(
                environment["warm_cache_seed"]["identity"]["tools"]["lld_link"][
                    "path"
                ]
            )
            lld.write_bytes(b"drifted-lld-link-tool")
            with self.assertRaisesRegex(
                harness.HarnessError, "tool lld_link bytes drifted"
            ):
                combine.combine_runs([cold], root / "combined")

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")

            def mutate_invocation(receipt: dict) -> None:
                receipt["seed_invocation"]["argv"][-1] = str(
                    (root / "other-cache").resolve()
                )

            self._rewrite_retained_seed(cold, mutate_invocation)
            with self.assertRaisesRegex(
                harness.HarnessError, "invocation provenance drifted"
            ):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_machine_identity_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            warm = self._write_run(root, state="warm", run_id="warm-run")
            environment_path = warm / "environment.json"
            environment = json.loads(environment_path.read_text(encoding="utf-8"))
            environment["cpu"]["logical_cores"] = 16
            harness._json_dump(environment_path, environment)
            with self.assertRaisesRegex(harness.HarnessError, "identity/toolchain drift"):
                combine.combine_runs([cold, warm], root / "combined")

    def test_rejects_incomplete_machine_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            environment_path = cold / "environment.json"
            environment = json.loads(environment_path.read_text(encoding="utf-8"))
            environment["power"]["active_scheme"] = None
            harness._json_dump(environment_path, environment)
            with self.assertRaisesRegex(harness.HarnessError, "machine identity is incomplete"):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_environment_flags_that_differ_from_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            environment_path = cold / "environment.json"
            environment = json.loads(environment_path.read_text(encoding="utf-8"))
            environment["flags"]["compiler"] = ["-O0"]
            harness._json_dump(environment_path, environment)
            with self.assertRaisesRegex(harness.HarnessError, "flags differ"):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_raw_cache_misclassification(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            warm = self._write_run(root, state="warm", run_id="warm-run")
            samples_path = warm / "samples.jsonl"
            rows = [json.loads(line) for line in samples_path.read_text().splitlines()]
            rows[0]["cache"]["thinlto_cache"] = "cold"
            samples_path.write_text(
                "".join(harness._json_line(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            summary_path = warm / "summary.json"
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            summary["samples_jsonl"] = harness._file_record(samples_path)
            harness._json_dump(summary_path, summary)
            with self.assertRaisesRegex(harness.HarnessError, "cache classification"):
                combine.combine_runs([cold, warm], root / "combined")

    def test_rejects_coordinated_eligibility_field_tampering(self) -> None:
        mutations = {
            "rss_complete": lambda rows: rows[0].__setitem__("rss_complete", False),
            "measurement_errors": lambda rows: rows[0].__setitem__(
                "measurement_errors", ["forged measurement failure"]
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                cold = self._write_run(root, state="cold", run_id="cold-run")
                self._rewrite_samples_and_summary(cold, mutate)
                with self.assertRaisesRegex(
                    harness.HarnessError, "rss_complete formula mismatch"
                ):
                    combine.combine_runs([cold], root / "combined")

    def test_rejects_coordinated_artifact_list_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            self._rewrite_samples_and_summary(
                cold, lambda rows: rows[0].__setitem__("artifacts", [])
            )
            with self.assertRaisesRegex(harness.HarnessError, "artifact provenance"):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_coordinated_stream_metadata_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")

            def mutate(rows: list[dict]) -> None:
                rows[0]["stdout"]["sha256"] = "f" * 64

            self._rewrite_samples_and_summary(cold, mutate)
            with self.assertRaisesRegex(harness.HarnessError, "stream provenance"):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_coordinated_runner_summary_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            forged = {
                "status_counts": {"pass": 1, "fail": 0, "skip": 0},
                "suite_counts": {"forged": {"pass": 1, "fail": 0, "skip": 0}},
                "cases": [
                    {
                        "suite": "forged",
                        "name": "case",
                        "status": "pass",
                        "skip_reason": None,
                    }
                ],
                "cases_sha256": harness.runner_cases_contract(
                    "[PASS] forged: case\n"
                )["sha256"],
                "reported_exit_code": 0,
            }
            self._rewrite_samples_and_summary(
                cold, lambda rows: rows[0].__setitem__("runner_summary", forged)
            )
            with self.assertRaisesRegex(harness.HarnessError, "runner summary provenance"):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_coordinated_runtime_error_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")

            def mutate(rows: list[dict]) -> None:
                rows[0]["runner_runtime"]["errors"] = ["forged runtime failure"]

            self._rewrite_samples_and_summary(cold, mutate)
            with self.assertRaisesRegex(harness.HarnessError, "runtime provenance"):
                combine.combine_runs([cold], root / "combined")

    def test_rejects_duplicate_lane_across_runs(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            first = self._write_run(root, state="cold", run_id="cold-one")
            second = self._write_run(root, state="cold", run_id="cold-two")
            with self.assertRaisesRegex(harness.HarnessError, "duplicate lane"):
                combine.combine_runs([first, second], root / "combined")

    def test_rejects_missing_cold_warm_coverage(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cold = self._write_run(root, state="cold", run_id="cold-run")
            with self.assertRaisesRegex(harness.HarnessError, "coverage mismatch"):
                combine.combine_runs([cold], root / "combined")


if __name__ == "__main__":
    unittest.main()
