from __future__ import annotations

import io
import json
import os
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import run as harness
import windows_job
from windows_job import (
    current_process_handle_count,
    preflight_job_support,
    run_in_job,
)


def phase_errors(classified: harness.PhaseValidation) -> list[str]:
    return [*classified.hard_errors, *classified.eligibility_errors]


class ManifestAndPolicyTests(unittest.TestCase):
    def test_manifest_and_schema_self_validate(self) -> None:
        manifest = harness._load_json(harness.DEFAULT_MANIFEST)
        schema = harness._load_json(harness.DEFAULT_RESULT_SCHEMA)
        harness.validate_manifest(manifest)
        harness.validate_schema_definition(schema)
        lanes = harness.expand_lanes(manifest)
        self.assertEqual(len(lanes), len(manifest["lanes"]) * 2)
        self.assertEqual(len({lane["case_id"] for lane in lanes}), len(lanes))
        self.assertTrue(any(lane["case_id"] == "full_gate_cold" for lane in lanes))
        self.assertTrue(any(lane["case_id"] == "full_gate_warm" for lane in lanes))

        by_base = {lane["case_id"]: lane for lane in manifest["lanes"]}
        timed = by_base["tiny_hello_check"]
        control = by_base["tiny_hello_check_no_phase"]
        for field in (
            "policy",
            "cache_states",
            "argv",
            "cwd",
            "timeout_seconds",
            "expected_exit_codes",
            "requires",
            "runner_summary",
            "artifacts",
        ):
            self.assertEqual(timed[field], control[field])
        self.assertTrue(timed["compiler_phase_timing"])
        self.assertFalse(timed["runner_phase_timing"])
        self.assertFalse(control["compiler_phase_timing"])
        self.assertFalse(control["runner_phase_timing"])
        self.assertEqual(control["phase_trace_paths"], [])

        runner_ids = {
            "filtered_e2e_bool_ops",
            "suite_e2e",
            "suite_golden",
            "suite_rc",
            "suite_structural",
            "suite_parity",
            "suite_self_compile",
            "full_gate",
        }
        self.assertEqual(
            {
                lane["case_id"]
                for lane in manifest["lanes"]
                if lane["runner_phase_timing"]
            },
            runner_ids,
        )
        for lane in manifest["lanes"]:
            self.assertFalse(
                sum(
                    lane[field]
                    for field in (
                        "compiler_phase_timing",
                        "runner_phase_timing",
                        "bootstrap_phase_timing",
                    )
                ) > 1
            )
            if lane["case_id"] in runner_ids:
                self.assertEqual(
                    lane["argv"][-1],
                    f"--phase-timing={harness.RUNNER_TRACE_PATH}",
                )
                self.assertEqual(lane["phase_trace_paths"], [harness.RUNNER_TRACE_PATH])

    def test_formal_manifest_is_exact_byte_pinned(self) -> None:
        harness.validate_formal_manifest_bytes(harness.DEFAULT_MANIFEST)
        original = harness.DEFAULT_MANIFEST.read_bytes()
        self.assertNotIn(b"\r\n", original)
        attributes = subprocess.run(
            [
                "git", "-C", str(harness.REPO_ROOT), "check-attr", "text", "eol",
                "--", "bench/check/manifest.json",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=True,
        ).stdout
        self.assertIn("text: set", attributes)
        self.assertIn("eol: lf", attributes)
        manifest = harness._load_json(harness.DEFAULT_MANIFEST)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            drifts = {
                "byte": original + b" ",
                "crlf": original.replace(b"\n", b"\r\n"),
                "reduced": json.dumps(
                    {**manifest, "lanes": manifest["lanes"][:1]},
                    ensure_ascii=False,
                ).encode("utf-8"),
                "reordered": json.dumps(
                    manifest, sort_keys=True, ensure_ascii=False
                ).encode("utf-8"),
            }
            for name, data in drifts.items():
                path = root / f"{name}.json"
                path.write_bytes(data)
                with self.subTest(name=name), self.assertRaisesRegex(
                    harness.HarnessError, "formal manifest bytes differ"
                ):
                    harness.validate_formal_manifest_bytes(path)

    def test_manifest_rejects_ambiguous_or_unowned_phase_timing(self) -> None:
        manifest = harness._load_json(harness.DEFAULT_MANIFEST)
        ambiguous = json.loads(json.dumps(manifest))
        runner_lane = next(
            lane
            for lane in ambiguous["lanes"]
            if lane["case_id"] == "suite_parity"
        )
        runner_lane["compiler_phase_timing"] = True
        with self.assertRaisesRegex(harness.HarnessError, "cannot enable"):
            harness.validate_manifest(ambiguous)

        unowned = json.loads(json.dumps(manifest))
        runner_lane = next(
            lane
            for lane in unowned["lanes"]
            if lane["case_id"] == "suite_parity"
        )
        runner_lane["runner_phase_timing"] = False
        with self.assertRaisesRegex(harness.HarnessError, "exactly one timing mode"):
            harness.validate_manifest(unowned)

        arbitrary = json.loads(json.dumps(manifest))
        lane = next(
            lane for lane in arbitrary["lanes"] if lane["case_id"] == "hello_build"
        )
        lane["bootstrap_phase_timing"] = True
        lane["phase_trace_paths"] = ["{sample_dir}/arbitrary.jsonl"]
        with self.assertRaisesRegex(harness.HarnessError, "reserved"):
            harness.validate_manifest(arbitrary)

        drifted = json.loads(json.dumps(manifest))
        lane = next(
            lane
            for lane in drifted["lanes"]
            if lane["case_id"] == "tracked_bootstrap_build"
        )
        lane["artifacts"] = lane["artifacts"][:-1]
        with self.assertRaisesRegex(harness.HarnessError, "recipe boundary"):
            harness.validate_manifest(drifted)

    def test_explicit_vorton_is_probe_only(self) -> None:
        with self.assertRaisesRegex(harness.HarnessError, "restricted to --probe"):
            harness.main(["--list", "--vorton", str(Path(sys.executable).resolve())])

    def test_result_schema_rejects_unknown_root_field(self) -> None:
        schema = harness._load_json(harness.DEFAULT_RESULT_SCHEMA)
        with self.assertRaises(harness.HarnessError):
            harness.validate_json({"unexpected": True}, schema)

    def test_result_schema_requires_strict_phase_trace_wrapper(self) -> None:
        schema = harness._load_json(harness.DEFAULT_RESULT_SCHEMA)
        phase_schema = schema["properties"]["phase_traces"]
        with self.assertRaisesRegex(harness.HarnessError, "read_error"):
            harness.validate_json(
                [{"path": "trace.jsonl", "line": 1, "value": {}}],
                phase_schema,
            )

    def test_result_schema_v3_definition_is_pinned_before_data_load(self) -> None:
        schema = harness._load_json(harness.DEFAULT_RESULT_SCHEMA)
        old = json.loads(json.dumps(schema))
        old["$id"] = "vorton.check-benchmark.invocation.v1"
        old["properties"]["schema"]["const"] = old["$id"]
        with self.assertRaisesRegex(harness.HarnessError, r"\$id"):
            harness.validate_schema_definition(old)

        lax = json.loads(json.dumps(schema))
        lax["properties"]["runner_summary"]["properties"]["suite_counts"] = {
            "type": "object"
        }
        with self.assertRaisesRegex(harness.HarnessError, "canonical invocation.v3"):
            harness.validate_schema_definition(lax)

    def test_strict_json_rejects_top_level_and_nested_duplicate_keys(self) -> None:
        for text in ('{"a":1,"a":2}', '{"outer":{"a":1,"a":2}}'):
            with self.subTest(text=text), self.assertRaisesRegex(
                harness.DuplicateJsonKeyError, "duplicate JSON key"
            ):
                harness._strict_json_loads(text, "fixture")

    def test_runner_summary_requires_exact_counts_and_final_exit(self) -> None:
        expected = harness.runner_cases_contract("[PASS] e2e: hello\n")
        contract = {
            "schema": harness.RUNNER_SUMMARY_CONTRACT_SCHEMA,
            "expected_total": 1,
            "expected_status_counts": {"pass": 1, "fail": 0, "skip": 0},
            "expected_suite_counts": {
                "e2e": {"pass": 1, "fail": 0, "skip": 0}
            },
            "expected_cases_sha256": expected["sha256"],
            "skip_policy": "exact",
            "fail_policy": "zero",
            "reported_exit_policy": "required_match_raw",
        }
        harness._validate_runner_summary_contract(contract, "fixture")
        cases = {
            "missing_final_exit": (
                "[PASS] e2e: hello\n", 0, "missing its unique final"
            ),
            "reported_raw_mismatch": (
                "[PASS] e2e: hello\nExit code: 0 (all 1 tests passed)\n",
                1,
                "does not match",
            ),
            "exit_zero_with_failure": (
                "[FAIL] e2e: hello\nExit code: 0 (all 0 tests passed)\n",
                0,
                "failure count",
            ),
            "reduced_count": (
                "Exit code: 0 (all 0 tests passed)\n",
                0,
                "status counts",
            ),
        }
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, (text, raw_exit, error) in cases.items():
                with self.subTest(case=name):
                    stdout = root / f"{name}.txt"
                    stdout.write_text(text, encoding="utf-8")
                    summary = harness._runner_summary(stdout)
                    assert summary is not None
                    with self.assertRaisesRegex(harness.HarnessError, error):
                        harness._validate_runner_summary_result(
                            summary, contract, raw_exit
                        )

    def test_runner_case_identity_status_and_skip_reason_are_exact(self) -> None:
        valid = (
            "[PASS] e2e: alpha.vorton\n"
            "[SKIP] e2e: beta.vorton -- known limitation\n"
            "Exit code: 0 (all 1 tests passed)\n"
        )
        expected = harness.runner_cases_contract(valid)
        contract = {
            "schema": harness.RUNNER_SUMMARY_CONTRACT_SCHEMA,
            "expected_total": 2,
            "expected_status_counts": {"pass": 1, "fail": 0, "skip": 1},
            "expected_suite_counts": {
                "e2e": {"pass": 1, "fail": 0, "skip": 1}
            },
            "expected_cases_sha256": expected["sha256"],
            "skip_policy": "exact",
            "fail_policy": "zero",
            "reported_exit_policy": "required_match_raw",
        }
        harness._validate_runner_summary_contract(contract, "fixture")
        valid_summary = harness._runner_summary_from_text(valid)
        assert valid_summary is not None
        harness._validate_runner_summary_result(valid_summary, contract, 0)
        self.assertEqual(valid_summary["cases"], expected["cases"])

        drifts = {
            "identity/status swap": (
                "[SKIP] e2e: alpha.vorton -- known limitation\n"
                "[PASS] e2e: beta.vorton\n"
                "Exit code: 0 (all 1 tests passed)\n"
            ),
            "skip reason": (
                "[PASS] e2e: alpha.vorton\n"
                "[SKIP] e2e: beta.vorton -- different limitation\n"
                "Exit code: 0 (all 1 tests passed)\n"
            ),
        }
        for label, text in drifts.items():
            with self.subTest(label=label):
                summary = harness._runner_summary_from_text(text)
                assert summary is not None
                with self.assertRaisesRegex(
                    harness.HarnessError,
                    "identities/statuses/skip reasons",
                ):
                    harness._validate_runner_summary_result(summary, contract, 0)

    def test_manifest_binds_runner_contract_for_both_cache_states(self) -> None:
        manifest = harness._load_json(harness.DEFAULT_MANIFEST)
        expanded = harness.expand_lanes(manifest)
        runner_lanes = [lane for lane in expanded if lane["runner_summary"]]
        self.assertTrue(runner_lanes)
        for lane in runner_lanes:
            with self.subTest(case=lane["case_id"]):
                contract = lane["runner_summary"]
                self.assertEqual(contract["expected_status_counts"]["fail"], 0)
                self.assertEqual(
                    sum(contract["expected_status_counts"].values()),
                    contract["expected_total"],
                )
        full = {
            lane["case_id"]: lane["runner_summary"] for lane in expanded
        }
        self.assertEqual(full["full_gate_cold"], full["full_gate_warm"])
        self.assertEqual(full["full_gate_cold"]["expected_total"], 1556)
        expected_digests = {
            "filtered_e2e_bool_ops_cold": "c24956c9f289e20271d588326f63849a20cd3567f341980909353d5cf94db693",
            "suite_e2e_cold": "94dd2398e67dcd493be0bc72834fed04e0abeb0e6f7cee7e47055170ad8eac49",
            "suite_golden_cold": "898cb7eb066ec50aedb0f7c4c338d954c80cb39b7e9e2d69557ae790d2304935",
            "suite_rc_cold": "24025bea17882a363e0bef31403fbc593ceb7a2cbf67db15ea6dbf29b9059c55",
            "suite_structural_cold": "3ff7ba79cfc784ed524a8535c93673856771ab6613484634c7b9c5947a20870f",
            "suite_parity_cold": "ae4ee4b1e28d27e79ea6143a199ead811e680bb3d097a19068904744af43c744",
            "suite_self_compile_cold": "9f0035d2c3dec96c0c5f702722da3302dce7a4c4afbc62ded164fcab9257151e",
            "full_gate_cold": "60d5f969d5ea1dbe245779498aaa53854e99621cfc9a9e207390404609b97c63",
        }
        self.assertEqual(
            {
                case_id: full[case_id]["expected_cases_sha256"]
                for case_id in expected_digests
            },
            expected_digests,
        )

    def test_filtered_e2e_lane_binds_unique_bool_ops_case(self) -> None:
        manifest = harness._load_json(harness.DEFAULT_MANIFEST)
        by_base = {lane["case_id"]: lane for lane in manifest["lanes"]}

        self.assertNotIn("filtered_e2e_hello", by_base)
        lane = by_base["filtered_e2e_bool_ops"]
        self.assertEqual(
            lane["argv"],
            [
                "{python}",
                "{repo}/tests/run_tests.py",
                "--suite",
                "e2e",
                "--filter",
                "bool_ops.vorton",
                "--phase-timing={sample_dir}/runner-phase-timing.jsonl",
            ],
        )
        self.assertEqual(lane["runner_summary"]["expected_total"], 1)
        self.assertEqual(
            lane["runner_summary"]["expected_status_counts"],
            {"pass": 1, "fail": 0, "skip": 0},
        )
        expected_digest = "c24956c9f289e20271d588326f63849a20cd3567f341980909353d5cf94db693"
        self.assertEqual(
            harness.runner_cases_contract("[PASS] e2e: bool_ops.vorton\n")["sha256"],
            expected_digest,
        )
        self.assertEqual(
            lane["runner_summary"]["expected_cases_sha256"], expected_digest
        )

    def test_warm_cache_receipt_rejects_wrong_recipe_and_byte_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            cache = root / "vorton-lang-thinlto-cache"
            cache.mkdir()
            (cache / "seed.bin").write_bytes(b"seed")
            manifest = {
                "fingerprint_flags": {
                    "compiler": ["-O3"],
                    "runtime": ["-O3"],
                    "link": ["-flto=thin"],
                }
            }
            source = {
                "git_sha": "a" * 40,
                "git_dirty": False,
                **{
                    name: {
                        "path": str((root / name).resolve()),
                        "sha256": character * 64,
                        "bytes": 1,
                    }
                    for name, character in (
                        ("dist_c", "b"), ("runtime", "c"), ("bootstrap", "d")
                    )
                },
            }
            tool_records = {
                name: {
                    "path": str((root / f"{name}.exe").resolve()),
                    "version": "fixture",
                    "sha256": character * 64,
                }
                for name, character in (
                    ("python", "1"), ("clang", "2"), ("clangxx", "3"),
                    ("lld_link", "6"),
                )
            }
            build_output = {}
            for name, filename in harness.WARM_CACHE_BUILD_FILES.items():
                path = root / filename
                path.write_bytes(name.encode("utf-8"))
                build_output[name] = harness._file_record(path)
            recipe = {
                "argv": ["fixture-seed"],
                "cwd": str(root),
                "timeout_seconds": harness.WARM_CACHE_SEED_TIMEOUT_SECONDS,
            }
            receipt = {
                "schema": harness.WARM_CACHE_RECEIPT_SCHEMA,
                "recipe_version": 2,
                "source": source,
                "tools": tool_records,
                "flags": harness._warm_cache_flags(manifest),
                "cache_path": str(cache),
                "seed_invocation": recipe,
                "outcome": {
                    "exit_code": 0,
                    "stdout": {"sha256": "4" * 64, "bytes": 0},
                    "stderr": {"sha256": "5" * 64, "bytes": 0},
                },
                "cache_inventory": harness._cache_inventory(cache),
                "build_output": build_output,
            }
            receipt_path, _output = harness._warm_cache_paths(cache)
            tools = {name: value["path"] for name, value in tool_records.items()}
            with (
                mock.patch.object(harness, "_warm_cache_source_identity", return_value=source),
                mock.patch.object(harness, "_seed_tool_records", return_value=tool_records),
                mock.patch.object(harness, "_warm_cache_seed_recipe", return_value=recipe),
                mock.patch.object(harness, "_warm_cache_build_output", return_value=build_output),
            ):
                wrong = json.loads(json.dumps(receipt))
                wrong["seed_invocation"]["argv"] = ["wrong-seed"]
                harness._json_dump(receipt_path, wrong)
                with self.assertRaisesRegex(harness.HarnessError, "seed seed_invocation drifted"):
                    harness.validate_warm_cache_seed(manifest, tools, cache)

                harness._json_dump(receipt_path, receipt)
                (cache / "seed.bin").write_bytes(b"drifted")
                with self.assertRaisesRegex(harness.HarnessError, "cache_inventory drifted"):
                    harness.validate_warm_cache_seed(manifest, tools, cache)

                selected = harness.formal_tools_from_seed(tools, receipt)
                self.assertEqual(selected["vorton"], build_output["vorton"]["path"])
                Path(build_output["vorton"]["path"]).write_bytes(b"forged")
                with self.assertRaisesRegex(
                    harness.HarnessError, "compiler bytes drifted"
                ):
                    harness.formal_tools_from_seed(tools, receipt)

    def test_warm_cache_build_output_replays_raw_lld_selection(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            cache = root / "vorton-lang-thinlto-cache"
            cache.mkdir()
            _receipt, output = harness._warm_cache_paths(cache)
            output.mkdir()
            manifest = harness._load_json(harness.DEFAULT_MANIFEST)
            lld = (root / "tools" / "lld-link.exe").resolve()
            tools = {
                "clang": str((root / "tools" / "clang.exe").resolve()),
                "clangxx": str((root / "tools" / "clang++.exe").resolve()),
                "lld_link": str(lld),
            }
            for name in ("compiler_object", "runtime_object", "vorton"):
                (output / harness.WARM_CACHE_BUILD_FILES[name]).write_bytes(
                    name.encode("utf-8")
                )
            commands = harness._expected_warm_cache_build_commands(
                manifest, tools, cache
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
                "claimed_path": str(lld),
                "selected_path": str(lld),
                "exit_code": 0,
                "stdout": harness._file_record(probe_stdout),
                "stderr": harness._file_record(probe_stderr),
            }
            harness._json_dump(
                output / harness.WARM_CACHE_BUILD_FILES["linker_binding"],
                binding,
            )
            records = harness._warm_cache_build_output(manifest, tools, cache)
            self.assertEqual(records["linker_probe_stdout"]["bytes"], 0)

            probe_stderr.write_bytes(
                f'{json.dumps(str(root / "other-lld-link"))} "-out:vorton.exe"\n'.encode(
                    "utf-8"
                )
            )
            binding["stderr"] = harness._file_record(probe_stderr)
            harness._json_dump(
                output / harness.WARM_CACHE_BUILD_FILES["linker_binding"],
                binding,
            )
            with self.assertRaisesRegex(harness.HarnessError, "raw linker probe"):
                harness._warm_cache_build_output(manifest, tools, cache)

    def test_empirical_p95_only_exists_for_twenty_one_values(self) -> None:
        self.assertIn("empirical_p95", harness._metric_stats(list(range(21))))
        self.assertNotIn("empirical_p95", harness._metric_stats(list(range(5))))

    def _fake_record(self, *, included: bool, warmup: bool, wall_ns: int) -> dict:
        record = {
            "included": included,
            "invalid_reason": (
                "warmup" if warmup else (
                    None if included else "measurement_errors: fixture quality"
                )
            ),
            "wall_ns": wall_ns,
            "cpu_user_ns": 1,
            "cpu_kernel_ns": 1,
            "peak_root_rss_bytes": 1,
            "sampled_peak_tree_rss_bytes": 1,
            "max_worker_peak_rss_bytes": 1,
            "peak_job_commit_bytes": 1,
            "rss_complete": True,
            "measurement_errors": [],
            "runner_runtime": {"errors": []},
        }
        return record

    def _exercise_policy(self, policy: str, wall_ns: int, valid: bool = True) -> dict:
        lane = {"case_id": "policy_probe_warm", "policy": policy}

        def fake_execute(**kwargs: object) -> dict:
            warmup = (
                policy == "direct_short"
                and int(kwargs["index"]) < harness.DIRECT_WARMUPS
            )
            return self._fake_record(
                included=valid and not warmup,
                warmup=warmup,
                wall_ns=wall_ns,
            )

        with (
            mock.patch.object(harness, "execute_invocation", side_effect=fake_execute),
            mock.patch.object(harness, "validate_json"),
        ):
            _records, summary = harness.run_lane(
                lane=lane,
                run_id="run",
                run_dir=Path("."),
                environment={},
                manifest_sha="0" * 64,
                result_schema={},
                tools={},
                thinlto_cache=Path("."),
                jsonl_stream=io.StringIO(),
            )
        return summary

    def test_direct_policy_retains_one_warmup_then_twenty_one(self) -> None:
        summary = self._exercise_policy("direct_short", wall_ns=1)
        self.assertEqual(summary["target_valid_samples"], 21)
        self.assertEqual(summary["valid_samples"], 21)
        self.assertEqual(summary["attempts"], 22)

    def test_warmup_semantic_failure_is_not_masked(self) -> None:
        reason = harness.derive_invalid_reason(
            policy="direct_short",
            index=0,
            invocation_error="launch failed",
            measurement={},
            exit_code=None,
            expected_exit_codes=[0],
            runner_expected=False,
            runner_summary=None,
            artifacts=[],
            phase_errors=["bad trace"],
            runtime_errors=["bad runtime"],
        )
        self.assertEqual(reason, "invocation_error: launch failed")

    def test_fatal_warmup_and_measured_attempt_stop_without_replacement(self) -> None:
        cases = (
            ("direct_short", "invocation_error: launch failed"),
            ("adaptive", "unexpected_exit: 1"),
        )
        for policy, reason in cases:
            with self.subTest(policy=policy):
                lane = {"case_id": f"fatal_{policy}", "policy": policy}

                def fake_execute(**_kwargs: object) -> dict:
                    record = self._fake_record(
                        included=False, warmup=False, wall_ns=1
                    )
                    record["invalid_reason"] = reason
                    return record

                with (
                    mock.patch.object(
                        harness, "execute_invocation", side_effect=fake_execute
                    ),
                    mock.patch.object(harness, "validate_json"),
                ):
                    records, summary = harness.run_lane(
                        lane=lane,
                        run_id="run",
                        run_dir=Path("."),
                        environment={},
                        manifest_sha="0" * 64,
                        result_schema={},
                        tools={},
                        thinlto_cache=Path("."),
                        jsonl_stream=io.StringIO(),
                    )
                self.assertEqual(len(records), 1)
                self.assertEqual(summary["attempts"], 1)
                self.assertFalse(summary["complete"])
                self.assertEqual(harness._formal_completion([summary]), (False, 1))

    def test_adaptive_policy_uses_three_for_long_first_valid(self) -> None:
        summary = self._exercise_policy(
            "adaptive", wall_ns=harness.LONG_LANE_THRESHOLD_NS
        )
        self.assertEqual(summary["target_valid_samples"], 3)
        self.assertEqual(summary["attempts"], 3)

    def test_adaptive_policy_stops_after_target_plus_two_invalid_attempts(self) -> None:
        summary = self._exercise_policy("adaptive", wall_ns=1, valid=False)
        self.assertEqual(summary["target_valid_samples"], 5)
        self.assertEqual(summary["attempts"], 7)
        self.assertFalse(summary["complete"])

    def test_incomplete_rss_is_invalid_and_explicit_in_summary(self) -> None:
        measurement = harness._empty_metrics()
        measurement.update(
            {
                "exit_code": 0,
                "wall_ns": 1,
                "cpu_user_ns": 1,
                "cpu_kernel_ns": 1,
                "peak_root_rss_bytes": 1,
                "peak_job_commit_bytes": 1,
                "sampled_peak_tree_rss_bytes": 1,
                "process_count": {"total": 1},
                "job_io": {},
                "rss_complete": False,
            }
        )
        reason = harness.derive_invalid_reason(
            policy="adaptive",
            index=0,
            invocation_error=None,
            measurement=measurement,
            exit_code=measurement["exit_code"],
            expected_exit_codes=[0],
            runner_expected=False,
            runner_summary=None,
            artifacts=[],
            phase_errors=[],
            runtime_errors=[],
        )
        self.assertEqual(reason, "rss_incomplete")
        record = self._fake_record(included=False, warmup=False, wall_ns=1)
        record["rss_complete"] = False
        record["sampled_peak_tree_rss_bytes"] = 7
        record["measurement_errors"] = ["missed worker"]
        summary = harness.summarize_lane(
            {"case_id": "quality", "policy": "adaptive"}, [record], 1
        )
        self.assertEqual(summary["resource_quality"]["rss_incomplete_samples"], 1)
        self.assertEqual(summary["resource_quality"]["measurement_error_samples"], 1)
        self.assertEqual(
            summary["resource_quality"]["rss_lower_bound"]["median"], 7
        )

    def test_runner_runtime_isolation_restores_ignored_root_object(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            source = repo / "vorton_runtime.cpp"
            root_object = repo / "vorton_runtime.o"
            prepared = repo / "prepared.o"
            source.write_text("runtime", encoding="utf-8")
            root_object.write_bytes(b"original")
            prepared.write_bytes(b"prepared")
            setup = {
                "mode": "warm",
                "root_path": str(root_object),
                "source_sha256": harness._sha256_file(source),
                "flags": ["-O2"],
                "original_root": harness._optional_file_state(root_object),
                "prepared": {
                    **harness._optional_file_state(prepared),
                    "path": str(prepared),
                },
            }
            lane = {"isolate_runner_runtime": True}
            sample = repo / "sample"
            sample.mkdir()
            with mock.patch.object(harness, "REPO_ROOT", repo):
                record, transaction = harness._begin_runner_runtime_isolation(
                    lane, setup, sample
                )
                self.assertEqual(root_object.read_bytes(), b"prepared")
                harness._finish_runner_runtime_isolation(record, setup, transaction)
            self.assertEqual(root_object.read_bytes(), b"original")
            self.assertTrue(record["restored"])
            self.assertEqual(record["errors"], [])

    def _runtime_transaction_fixture(
        self, repo: Path
    ) -> tuple[Path, dict, dict, Path]:
        source = repo / "vorton_runtime.cpp"
        root_object = repo / "vorton_runtime.o"
        prepared = repo / "prepared.o"
        source.write_text("runtime", encoding="utf-8")
        root_object.write_bytes(b"original")
        prepared.write_bytes(b"prepared")
        setup = {
            "mode": "warm",
            "root_path": str(root_object),
            "source_sha256": harness._sha256_file(source),
            "flags": ["-O2"],
            "original_root": harness._optional_file_state(root_object),
            "prepared": {
                **harness._optional_file_state(prepared),
                "path": str(prepared),
            },
        }
        sample = repo / "sample"
        sample.mkdir()
        return root_object, setup, {"isolate_runner_runtime": True}, sample

    def test_runtime_backup_failure_keeps_unique_root_untouched(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            root, setup, lane, sample = self._runtime_transaction_fixture(repo)
            real_replace = os.replace

            def fail_backup(source: object, destination: object) -> None:
                if Path(source) == root and ".backup.o" in str(destination):
                    raise OSError("injected backup failure")
                real_replace(source, destination)

            with (
                mock.patch.object(harness, "REPO_ROOT", repo),
                mock.patch.object(harness.os, "replace", side_effect=fail_backup),
                self.assertRaises(harness.HarnessError),
            ):
                harness._begin_runner_runtime_isolation(lane, setup, sample)
            self.assertEqual(root.read_bytes(), b"original")
            self.assertEqual(list(repo.glob("vorton_runtime.b176-*.backup.o")), [])
            self.assertEqual(list(repo.glob("vorton_runtime.b176-*.install.o")), [])

    def test_runtime_install_failure_restores_atomic_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            root, setup, lane, sample = self._runtime_transaction_fixture(repo)
            real_replace = os.replace

            def fail_install(source: object, destination: object) -> None:
                if ".install.o" in str(source) and Path(destination) == root:
                    raise OSError("injected install failure")
                real_replace(source, destination)

            with (
                mock.patch.object(harness, "REPO_ROOT", repo),
                mock.patch.object(harness.os, "replace", side_effect=fail_install),
                self.assertRaises(harness.HarnessError),
            ):
                harness._begin_runner_runtime_isolation(lane, setup, sample)
            self.assertEqual(root.read_bytes(), b"original")
            self.assertEqual(list(repo.glob("vorton_runtime.b176-*.backup.o")), [])
            self.assertEqual(list(repo.glob("vorton_runtime.b176-*.install.o")), [])

    def test_runtime_cleanup_failure_does_not_skip_original_restore(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            root, setup, lane, sample = self._runtime_transaction_fixture(repo)
            with mock.patch.object(harness, "REPO_ROOT", repo):
                record, transaction = harness._begin_runner_runtime_isolation(
                    lane, setup, sample
                )
                staging = Path(transaction["staging"])
                staging.write_bytes(b"stale-install")
                real_unlink = Path.unlink

                def fail_staging(path: Path, *args: object, **kwargs: object) -> None:
                    if path == staging:
                        raise OSError("injected cleanup failure")
                    real_unlink(path, *args, **kwargs)

                with mock.patch.object(Path, "unlink", new=fail_staging):
                    harness._finish_runner_runtime_isolation(
                        record, setup, transaction
                    )
            self.assertEqual(root.read_bytes(), b"original")
            self.assertTrue(record["restored"])
            self.assertFalse(record["backup_exists_after"])
            self.assertTrue(record["staging_exists_after"])
            self.assertTrue(any("staging cleanup failed" in e for e in record["errors"]))
            staging.unlink()

    def test_runtime_restore_failure_retains_backup_as_unique_original(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            root, setup, lane, sample = self._runtime_transaction_fixture(repo)
            with mock.patch.object(harness, "REPO_ROOT", repo):
                record, transaction = harness._begin_runner_runtime_isolation(
                    lane, setup, sample
                )
                backup = Path(transaction["backup"])
                real_replace = os.replace

                def fail_restore(source: object, destination: object) -> None:
                    if Path(source) == backup and Path(destination) == root:
                        raise OSError("injected restore failure")
                    real_replace(source, destination)

                with mock.patch.object(
                    harness.os, "replace", side_effect=fail_restore
                ):
                    harness._finish_runner_runtime_isolation(
                        record, setup, transaction
                    )
            self.assertEqual(root.read_bytes(), b"prepared")
            self.assertEqual(backup.read_bytes(), b"original")
            self.assertFalse(record["restored"])
            self.assertTrue(record["backup_exists_after"])
            self.assertTrue(any("restore failed" in e for e in record["errors"]))
            os.replace(backup, root)
            self.assertEqual(root.read_bytes(), b"original")


class AttemptBoundaryTests(unittest.TestCase):
    def _fixture(
        self, root: Path, *, index: int, timed_out: bool = False
    ) -> tuple[dict, dict, dict, Path]:
        run_dir = root.resolve()
        case_id = "boundary_cold"
        sample_id = f"{case_id}-{index:03d}-{index:08x}"
        sample_dir = run_dir / "samples" / case_id / sample_id
        sample_dir.mkdir(parents=True)
        trace = sample_dir / "trace.jsonl"
        entry = str((harness.REPO_ROOT / "tests" / "cases" / "hello.vorton").resolve())
        compiler = str((root / "vorton.exe").resolve())
        lane = {
            "case_id": case_id,
            "policy": "direct_short",
            "cache": {
                "thinlto_cache": "cold",
                "output": "fresh",
                "os_file_cache": "uncontrolled",
            },
            "argv": ["{vorton}", "check", entry],
            "cwd": "{repo}",
            "expected_exit_codes": [0],
            "runner_summary": None,
            "artifacts": [],
            "phase_trace_paths": ["{sample_dir}/trace.jsonl"],
            "compiler_phase_timing": True,
            "expected_executed_phases": [
                "input_entry_load",
                "entry_parse",
                "type_effect_check_lower",
                "command_total",
            ],
        }
        environment = {
            "run_id": "fixture-run",
            "source_sha": "b" * 40,
            "manifest_sha": "c" * 64,
            "tools": {
                "vorton": {"path": compiler, "sha256": "a" * 64}
            },
            "thinlto_cache_path": str((root / "thinlto-cache").resolve()),
        }
        rows = []
        for phase in harness.COMPILER_PHASE_ORDER:
            executed = phase in lane["expected_executed_phases"]
            rows.append(
                {
                    "schema": harness.COMPILER_PHASE_SCHEMA,
                    "schema_version": 1,
                    "lane": case_id,
                    "phase": phase,
                    "duration_ns": (
                        100 if phase == "command_total" else (10 if executed else 0)
                    ),
                    "unit": "ns",
                    "compiler_identity": "sha256:" + "a" * 64,
                    "source_identity": "git:" + "b" * 40,
                    "entry_file": entry,
                    "executed": executed,
                    "complete": True,
                    "command_success": True,
                }
            )
        trace.write_text(
            "".join(harness._json_line(row) + "\n" for row in rows),
            encoding="utf-8",
        )
        stdout_path = sample_dir / "stdout.txt"
        stderr_path = sample_dir / "stderr.txt"
        stdout_path.write_bytes(b"OK\n")
        stderr_path.write_bytes(b"")
        phase_records = harness._phase_trace_records([trace])
        record = {
            "schema": harness.RESULT_SCHEMA,
            "run_id": "fixture-run",
            "sample_id": sample_id,
            "sample_dir": str(sample_dir),
            "case_id": case_id,
            "index": index,
            "included": False,
            "source_sha": "b" * 40,
            "manifest_sha": "c" * 64,
            "argv": [
                compiler,
                "check",
                entry,
                f"--phase-timing={trace}",
                f"--phase-timing-lane={case_id}",
                "--phase-timing-compiler=sha256:" + "a" * 64,
                "--phase-timing-source=git:" + "b" * 40,
            ],
            "cwd": str(harness.REPO_ROOT.resolve()),
            "cache": lane["cache"],
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
            "root_pid": 1,
            "wall_ns": 200,
            "cpu_user_ns": 10,
            "cpu_kernel_ns": 5,
            "peak_root_rss_bytes": 1000,
            "sampled_peak_tree_rss_bytes": 1000,
            "max_worker_peak_rss_bytes": None,
            "peak_job_commit_bytes": 2000,
            "rss_poll_ms": harness.RSS_POLL_MS,
            "rss_samples_observed": 1,
            "rss_covered_ns": 200,
            "rss_coverage_ratio": 1.0,
            "rss_observed_process_count": 1,
            "rss_job_total_processes": 1,
            "rss_complete": True,
            "process_count": {"total": 1, "active_at_query": 0, "terminated": 1},
            "job_io": {
                "read_operations": 0,
                "write_operations": 0,
                "other_operations": 0,
                "read_bytes": 0,
                "write_bytes": 0,
                "other_bytes": 0,
            },
            "timed_out": timed_out,
            "measurement_errors": [],
            "exit": {"code": 0, "expected": True},
            "stdout": harness._file_record(stdout_path),
            "stderr": harness._file_record(stderr_path),
            "runner_summary": None,
            "artifacts": [],
            "phase_traces": phase_records,
            "invocation_error": None,
            "invalid_reason": None,
        }
        validated = harness.validate_attempt_boundary(
            record, lane, environment, run_dir,
            harness._load_json(harness.DEFAULT_RESULT_SCHEMA),
            verify_stored=False,
        )
        record["invalid_reason"] = validated.invalid_reason
        record["included"] = validated.invalid_reason is None
        return record, lane, environment, trace

    def test_phase_identity_tamper_is_hard_even_for_excluded_attempts(self) -> None:
        cases = ((0, False, "warmup"), (1, True, "timeout"))
        for index, timed_out, reason in cases:
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as temp:
                record, lane, environment, trace = self._fixture(
                    Path(temp), index=index, timed_out=timed_out
                )
                self.assertEqual(record["invalid_reason"], reason)
                rows = [
                    json.loads(line)
                    for line in trace.read_text(encoding="utf-8").splitlines()
                ]
                rows[0]["compiler_identity"] = "sha256:" + "f" * 64
                trace.write_text(
                    "".join(harness._json_line(row) + "\n" for row in rows),
                    encoding="utf-8",
                )
                record["phase_traces"] = harness._phase_trace_records([trace])
                with self.assertRaisesRegex(
                    harness.HarnessError, "hard phase trace.*compiler identity mismatch"
                ):
                    harness.validate_attempt_boundary(
                        record, lane, environment, Path(temp),
                        harness._load_json(harness.DEFAULT_RESULT_SCHEMA),
                        verify_stored=True,
                    )

    def test_sample_identity_cannot_cross_lane_or_traverse(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            record, lane, environment, _trace = self._fixture(
                Path(temp), index=1
            )
            record["sample_dir"] = str(
                (Path(temp) / "samples" / "other_cold" / record["sample_id"]).resolve()
            )
            with self.assertRaisesRegex(harness.HarnessError, "sample_dir provenance"):
                harness.validate_attempt_boundary(
                    record, lane, environment, Path(temp),
                    harness._load_json(harness.DEFAULT_RESULT_SCHEMA),
                    verify_stored=True,
                )
            record["sample_id"] = "boundary_cold-001-../escape"
            with self.assertRaisesRegex(
                harness.HarnessError, "required pattern|non-canonical sample_id"
            ):
                harness.validate_attempt_boundary(
                    record, lane, environment, Path(temp),
                    harness._load_json(harness.DEFAULT_RESULT_SCHEMA),
                    verify_stored=True,
                )

    def test_rss_structural_invariants_reject_coordinated_tampering(self) -> None:
        mutations = {
            "low_coverage": lambda record: record.update(
                rss_covered_ns=100, rss_coverage_ratio=0.5
            ),
            "observed_below_total": lambda record: record.update(
                rss_observed_process_count=0
            ),
            "errors_but_complete": lambda record: record.update(
                measurement_errors=["forged"], invocation_error="forged"
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(case=name), tempfile.TemporaryDirectory() as temp:
                record, lane, environment, _trace = self._fixture(
                    Path(temp), index=1
                )
                mutate(record)
                record["included"] = True
                record["invalid_reason"] = None
                with self.assertRaisesRegex(harness.HarnessError, "rss_complete formula"):
                    harness.validate_attempt_boundary(
                        record, lane, environment, Path(temp),
                        harness._load_json(harness.DEFAULT_RESULT_SCHEMA),
                        verify_stored=True,
                    )


class PhaseTimingTests(unittest.TestCase):
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
                "lane": "tiny_hello_check_cold",
                "phase": phase,
                "duration_ns": durations[phase],
                "unit": "ns",
                "compiler_identity": "sha256:" + "a" * 64,
                "source_identity": "git:" + "b" * 40,
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

    def _validate(self, rows: list[dict], *, wall_ns: int = 150) -> list[str]:
        return phase_errors(harness._classify_compiler_phase_rows(
            rows,
            expected_lane="tiny_hello_check_cold",
            expected_compiler_identity="sha256:" + "a" * 64,
            expected_source_identity="git:" + "b" * 40,
            expected_entry_file=str(
                (harness.REPO_ROOT / "tests" / "cases" / "hello.vorton").resolve()
            ),
            expected_success=True,
            expected_executed_phases=[
                "input_entry_load",
                "entry_parse",
                "type_effect_check_lower",
                "command_total",
            ],
            wall_ns=wall_ns,
        ))

    def test_compiler_phase_trace_validates_and_summarizes_accounting(self) -> None:
        rows = self._compiler_rows()
        self.assertEqual(self._validate(rows), [])
        record = {
            "included": True,
            "wall_ns": 150,
            "phase_traces": [
                {
                    "path": "trace.jsonl",
                    "line": index,
                    "value": row,
                    "read_error": None,
                }
                for index, row in enumerate(rows, 1)
            ],
        }
        summary = harness._summarize_compiler_phase_timing([record])
        assert summary is not None
        self.assertEqual(summary["sample_count"], 1)
        self.assertEqual(
            summary["accounting"]["measured_phase_sum_ns"]["median"], 60
        )
        self.assertEqual(
            summary["accounting"]["unattributed_command_ns"]["median"], 40
        )
        self.assertEqual(
            summary["accounting"]["outside_instrumented_command_ns"]["median"],
            50,
        )

    def test_bad_or_incomplete_compiler_trace_fails_closed(self) -> None:
        rows = self._compiler_rows()
        rows[2]["complete"] = False
        self.assertTrue(any("incomplete" in error for error in self._validate(rows)))
        rows = self._compiler_rows()
        rows[0]["schema_version"] = True
        self.assertTrue(
            any("schema/version" in error for error in self._validate(rows))
        )
        reason = harness.derive_invalid_reason(
            policy="adaptive",
            index=0,
            invocation_error=None,
            measurement={
                "timed_out": False,
                "exit_code": 0,
                "cpu_user_ns": 1,
                "cpu_kernel_ns": 1,
                "peak_root_rss_bytes": 1,
                "peak_job_commit_bytes": 1,
                "process_count": {"total": 1},
                "job_io": {},
                "measurement_errors": [],
                "rss_complete": True,
            },
            exit_code=0,
            expected_exit_codes=[0],
            runner_expected=False,
            runner_summary=None,
            artifacts=[],
            phase_errors=["compiler phase row 3 is incomplete"],
            runtime_errors=[],
        )
        self.assertEqual(
            reason,
            "phase_trace_invalid: compiler phase row 3 is incomplete",
        )

    def test_unknown_phase_trace_schema_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            sample_dir = Path(temp).resolve()
            path = sample_dir / "unknown.jsonl"
            row = self._compiler_rows()[0]
            row["schema"] = "unknown.phase.v1"
            errors = phase_errors(harness._classify_phase_trace_records(
                [
                    {
                        "path": str(path),
                        "line": 1,
                        "value": row,
                        "read_error": None,
                    }
                ],
                paths=[path],
                sample_dir=sample_dir,
                lane={
                    "case_id": "tiny_hello_check_cold",
                    "compiler_phase_timing": True,
                    "expected_executed_phases": [
                        "input_entry_load",
                        "entry_parse",
                        "type_effect_check_lower",
                        "command_total",
                    ],
                },
                environment={
                    "source_sha": "b" * 40,
                    "tools": {"vorton": {"sha256": "a" * 64}},
                },
                expected_entry_file=str(
                    (harness.REPO_ROOT / "tests" / "cases" / "hello.vorton").resolve()
                ),
                exit_code=0,
                wall_ns=150,
            ))
        self.assertTrue(any("schema mismatch" in error for error in errors))

    def test_phase_sum_and_command_total_must_fit_job_wall(self) -> None:
        rows = self._compiler_rows()
        rows[-1]["duration_ns"] = 50
        errors = self._validate(rows, wall_ns=40)
        self.assertTrue(any("phase sum" in error for error in errors))
        self.assertTrue(any("job wall" in error for error in errors))

    def test_entry_file_may_be_empty_only_when_input_is_skipped(self) -> None:
        rows = self._compiler_rows()
        for row in rows:
            row["entry_file"] = ""
        self.assertTrue(
            any("executed input_entry_load" in error for error in self._validate(rows))
        )
        rows[0]["executed"] = False
        rows[0]["duration_ns"] = 0
        errors = phase_errors(harness._classify_compiler_phase_rows(
            rows,
            expected_lane="tiny_hello_check_cold",
            expected_compiler_identity="sha256:" + "a" * 64,
            expected_source_identity="git:" + "b" * 40,
            expected_entry_file="",
            expected_success=True,
            expected_executed_phases=[
                "entry_parse",
                "type_effect_check_lower",
                "command_total",
            ],
            wall_ns=150,
        ))
        self.assertEqual(errors, [])

    def test_entry_file_is_bound_to_the_invocation_entry(self) -> None:
        rows = self._compiler_rows()
        forged = str((harness.REPO_ROOT / "compiler" / "main.vorton").resolve())
        for row in rows:
            row["entry_file"] = forged
        errors = self._validate(rows)
        self.assertTrue(any("entry_file identity mismatch" in error for error in errors))
        self.assertFalse(any("disagree on entry_file" in error for error in errors))

    def test_trace_wrappers_require_manifest_path_and_contiguous_lines(self) -> None:
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
            wrappers[1]["line"] = 3
            errors = phase_errors(harness._classify_phase_trace_records(
                wrappers,
                paths=[path],
                sample_dir=sample_dir,
                lane={
                    "case_id": "tiny_hello_check_cold",
                    "compiler_phase_timing": True,
                    "expected_executed_phases": [
                        "input_entry_load",
                        "entry_parse",
                        "type_effect_check_lower",
                        "command_total",
                    ],
                },
                environment={
                    "source_sha": "b" * 40,
                    "tools": {"vorton": {"sha256": "a" * 64}},
                },
                expected_entry_file=str(
                    (harness.REPO_ROOT / "tests" / "cases" / "hello.vorton").resolve()
                ),
                exit_code=0,
                wall_ns=150,
            ))
            self.assertTrue(any("unique and contiguous" in error for error in errors))
            outside = sample_dir.parent / "outside.jsonl"
            errors = phase_errors(harness._classify_phase_trace_records(
                [],
                paths=[outside],
                sample_dir=sample_dir,
                lane={"case_id": "bootstrap", "phase_trace_paths": [str(outside)]},
                environment={},
                expected_entry_file="",
                exit_code=0,
                wall_ns=150,
            ))
            self.assertTrue(any("escapes sample_dir" in error for error in errors))

    def test_duplicate_key_in_phase_trace_is_a_hard_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            sample_dir = Path(temp).resolve()
            path = sample_dir / "trace.jsonl"
            path.write_text('{"schema":"first","schema":"second"}\n', encoding="utf-8")
            wrappers = harness._phase_trace_records([path])
            self.assertEqual(wrappers[0]["read_error"], "duplicate_json_key")
            classified = harness._classify_phase_trace_records(
                wrappers,
                paths=[path],
                sample_dir=sample_dir,
                lane={
                    "case_id": "tiny_hello_check_cold",
                    "compiler_phase_timing": True,
                    "expected_executed_phases": ["command_total"],
                },
                environment={
                    "source_sha": "b" * 40,
                    "tools": {"vorton": {"sha256": "a" * 64}},
                },
                expected_entry_file="",
                exit_code=0,
                wall_ns=1,
            )
            self.assertTrue(
                any("duplicate JSON key" in error for error in classified.hard_errors)
            )

    def test_bootstrap_phase_schema_remains_supported_and_strict(self) -> None:
        rows = [
            {
                "schema": harness.BOOTSTRAP_PHASE_SCHEMA,
                "phase": phase,
                "argv": ["tool", phase],
                "wall_ns": 10,
                "exit_code": 0,
            }
            for phase in harness.BOOTSTRAP_PHASE_ORDER
        ]
        self.assertEqual(
            phase_errors(harness._classify_bootstrap_phase_rows(rows, wall_ns=40)), []
        )
        rows[0]["unknown"] = True
        self.assertTrue(
            any(
                "fields differ" in error
                for error in phase_errors(
                    harness._classify_bootstrap_phase_rows(rows, wall_ns=40)
                )
            )
        )

    def test_explicit_trace_mode_selects_bootstrap_only_when_both_flags_are_false(self) -> None:
        rows = [
            {
                "schema": harness.BOOTSTRAP_PHASE_SCHEMA,
                "phase": phase,
                "argv": ["tool", phase],
                "wall_ns": 10,
                "exit_code": 0,
            }
            for phase in harness.BOOTSTRAP_PHASE_ORDER
        ]
        with tempfile.TemporaryDirectory() as temp:
            sample_dir = Path(temp).resolve()
            path = sample_dir / "trace.jsonl"
            wrappers = [
                {
                    "path": str(path),
                    "line": index,
                    "value": row,
                    "read_error": None,
                }
                for index, row in enumerate(rows, 1)
            ]
            classified = harness._classify_phase_trace_records(
                wrappers,
                paths=[path],
                sample_dir=sample_dir,
                lane={
                    "case_id": "bootstrap_cold",
                    "compiler_phase_timing": False,
                    "runner_phase_timing": False,
                    "bootstrap_phase_timing": True,
                },
                environment={},
                expected_entry_file="",
                exit_code=0,
                wall_ns=40,
            )
            self.assertEqual(phase_errors(classified), [])

            implicit = harness._classify_phase_trace_records(
                wrappers,
                paths=[path],
                sample_dir=sample_dir,
                lane={
                    "case_id": "bootstrap_cold",
                    "compiler_phase_timing": False,
                    "runner_phase_timing": False,
                    "bootstrap_phase_timing": False,
                },
                environment={},
                expected_entry_file="",
                exit_code=0,
                wall_ns=40,
            )
            self.assertTrue(
                any("exactly one explicit" in error for error in implicit.hard_errors)
            )

    def test_timing_is_hidden_opt_in_and_defaults_to_no_state(self) -> None:
        cli = (harness.REPO_ROOT / "compiler" / "cli.vorton").read_text(encoding="utf-8")
        timing = (harness.REPO_ROOT / "compiler" / "phase_timing.vorton").read_text(
            encoding="utf-8"
        )
        self.assertIn("let mut phase_timing_file: Str? = none", cli)
        self.assertNotIn("--phase-timing", cli[cli.index("fn usage()") :])
        self.assertIn("state: PhaseTimingState?", timing)
        self.assertIn("none => PhaseTiming { state: none }", timing)
        self.assertIn("phase_id != state.next_phase", timing)
        self.assertIn("if state.next_phase != PHASE_COUNT", timing)
        self.assertNotIn("enabled: Bool", timing)

    def test_duplicate_finalize_rewrites_existing_trace_incomplete(self) -> None:
        timing = (harness.REPO_ROOT / "compiler" / "phase_timing.vorton").read_text(
            encoding="utf-8"
        )
        finish = timing[
            timing.index("pub fn finish_command") : timing.index(
                "fn write_phase_timing_trace"
            )
        ]
        duplicate = finish[
            finish.index("if state.finalized") : finish.index(
                "state.finalized = true"
            )
        ]
        self.assertIn("state.integrity = false", duplicate)
        self.assertIn(
            "write_phase_timing_trace(state, false, command_success)", duplicate
        )
        self.assertIn("return", duplicate)

    def test_generated_c_disabled_path_allocates_only_inert_wrapper(self) -> None:
        generated = (
            harness.REPO_ROOT / "compiler" / "dist-c" / "main.c"
        ).read_text(encoding="utf-8")
        constructor_name = "vortonmod_vorton__phase__timing_m_m__PhaseTiming"
        constructor_start = generated.index(f"void* {constructor_name}(void* a0) {{")
        constructor_end = generated.index("\n}\n", constructor_start) + 3
        constructor = generated[constructor_start:constructor_end]
        allocation = re.search(r"vorton_alloc\([^;]+\);", constructor)
        assert allocation is not None

        function_name = "vortonmod_vorton__phase__timing_m_m__new__phase__timing"
        definitions = list(
            re.finditer(
                rf"^void\* {re.escape(function_name)}\("
                r"void\* r_output_path, void\* r_lane, "
                r"void\* r_compiler_identity, void\* r_source_identity, "
                r"void\* r_entry_file\) \{$",
                generated,
                re.MULTILINE,
            )
        )
        self.assertEqual(len(definitions), 1)
        function_start = definitions[0].start()
        function_end = generated.index("\n}\n", definitions[0].end()) + 3
        function = generated[function_start:function_end]
        branch = re.search(
            r"if \(\*\(int64_t\*\)\w+ != 1\) goto (?P<label>\w+);"
            r"(?P<body>.*?)\n(?P=label):;",
            function,
            re.DOTALL,
        )
        assert branch is not None
        disabled = branch.group("body")
        self.assertEqual(disabled.count("vorton_alloc("), 1)
        self.assertIn(allocation.group(0), disabled)
        self.assertIn("vorton_Option_none()", disabled)
        for forbidden in (
            "vorton_str_from_cstr", "vorton_list_new", "vorton_sb_new",
            "vorton_bench_monotonic_ns", "vorton_path_resolve", "vorton_write_file",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, disabled)


class RunnerPhaseTimingTests(unittest.TestCase):
    @staticmethod
    def _row(
        sequence: int,
        *,
        suite: str | None,
        case: str | None,
        stage: str,
        duration_ns: int,
        executed: bool,
        complete: bool,
        outcome: str,
        exit_code: int | None,
        command_category: str | None,
    ) -> dict:
        return {
            "schema": harness.RUNNER_PHASE_SCHEMA,
            "version": 1,
            "sequence": sequence,
            "suite": suite,
            "case": case,
            "stage": stage,
            "duration_ns": duration_ns,
            "executed": executed,
            "complete": complete,
            "outcome": outcome,
            "exit_code": exit_code,
            "command_category": command_category,
        }

    def _e2e_rows(self) -> list[dict]:
        rows = [
            self._row(
                1, suite=None, case="runner",
                stage="compiler_anchor_compile", duration_ns=10,
                executed=True, complete=True, outcome="success", exit_code=0,
                command_category="clang",
            ),
            self._row(
                2, suite=None, case="runner",
                stage="compiler_runtime_compile", duration_ns=20,
                executed=True, complete=True, outcome="success", exit_code=0,
                command_category="clang",
            ),
            self._row(
                3, suite=None, case="runner",
                stage="compiler_link", duration_ns=30,
                executed=True, complete=True, outcome="success", exit_code=0,
                command_category="clang",
            ),
            self._row(
                4, suite=None, case="runner", stage="runtime_prepare",
                duration_ns=2, executed=False, complete=True, outcome="cached",
                exit_code=None, command_category=None,
            ),
            # A non-zero child is a legal negative test event.  Only the final
            # runner result determines whether the invocation succeeded.
            self._row(
                5, suite="e2e", case="negative/example.vorton",
                stage="vorton_check", duration_ns=40, executed=True,
                complete=True, outcome="nonzero", exit_code=1,
                command_category="vorton",
            ),
            self._row(
                6, suite="e2e", case=None, stage="orchestration_residual",
                duration_ns=8, executed=True, complete=True,
                outcome="completed", exit_code=None, command_category=None,
            ),
            self._row(
                7, suite="e2e", case=None, stage="suite_total",
                duration_ns=48, executed=True, complete=True,
                outcome="completed", exit_code=None, command_category=None,
            ),
            self._row(
                8, suite=None, case="runner", stage="orchestration_residual",
                duration_ns=3, executed=True, complete=True, outcome="success",
                exit_code=0, command_category=None,
            ),
            self._row(
                9, suite=None, case="runner", stage="runner_total",
                duration_ns=113, executed=True, complete=True, outcome="success",
                exit_code=0, command_category=None,
            ),
        ]
        return rows

    def _classify(self, rows: list[dict], *, wall_ns: int = 120) -> harness.PhaseValidation:
        return harness._classify_runner_phase_rows(
            rows,
            expected_suites=("e2e",),
            expected_exit_code=0,
            wall_ns=wall_ns,
        )

    def _insert_early_runner_summary(self, *, pair: bool) -> list[dict]:
        rows = self._e2e_rows()
        early = [
            self._row(
                0, suite=None, case="runner", stage="orchestration_residual",
                duration_ns=0, executed=True, complete=True, outcome="success",
                exit_code=0, command_category=None,
            )
        ]
        if pair:
            early.append(
                self._row(
                    0, suite=None, case="runner", stage="runner_total",
                    duration_ns=0, executed=True, complete=True, outcome="success",
                    exit_code=0, command_category=None,
                )
            )
        rows[4:4] = early
        for sequence, row in enumerate(rows, 1):
            row["sequence"] = sequence
        return rows

    def test_validator_schema_and_fields_match_runner_source(self) -> None:
        runner = runpy.run_path(str(harness.REPO_ROOT / "tests" / "run_tests.py"))
        self.assertEqual(runner["PHASE_TIMING_SCHEMA"], harness.RUNNER_PHASE_SCHEMA)
        self.assertEqual(runner["PHASE_TIMING_FIELDS"], harness.RUNNER_PHASE_FIELDS)
        self.assertEqual(len(harness.RUNNER_PHASE_FIELDS), 12)

    def test_valid_runner_trace_and_negative_child_are_eligible(self) -> None:
        classified = self._classify(self._e2e_rows())
        self.assertEqual(classified.hard_errors, ())
        self.assertEqual(classified.eligibility_errors, ())

    def test_unknown_schema_or_extra_thirteenth_field_is_hard(self) -> None:
        for name, mutate in (
            (
                "schema",
                lambda rows: rows[0].__setitem__("schema", "unknown.runner.v1"),
            ),
            (
                "field",
                lambda rows: rows[0].__setitem__("unexpected_thirteenth", True),
            ),
        ):
            rows = self._e2e_rows()
            mutate(rows)
            with self.subTest(name=name):
                classified = self._classify(rows)
                self.assertTrue(classified.hard_errors)

    def test_non_string_or_unknown_stage_is_hard_without_classifier_exception(self) -> None:
        for stage in ([], {}, "future_stage"):
            rows = self._e2e_rows()
            rows[4]["stage"] = stage
            with self.subTest(stage=repr(stage)):
                classified = self._classify(rows)
                self.assertTrue(
                    any("unknown stage" in error for error in classified.hard_errors)
                )

    def test_sequence_gap_is_hard(self) -> None:
        rows = self._e2e_rows()
        rows[4]["sequence"] = 6
        self.assertTrue(
            any("sequence" in error for error in self._classify(rows).hard_errors)
        )

    def test_early_runner_summary_pair_or_single_is_hard(self) -> None:
        for pair in (True, False):
            rows = self._insert_early_runner_summary(pair=pair)
            with self.subTest(pair=pair):
                classified = self._classify(rows)
                self.assertTrue(
                    any(
                        "unique terminal" in error
                        for error in classified.hard_errors
                    )
                )
                with self.assertRaisesRegex(harness.HarnessError, "unique terminal"):
                    harness._summarize_runner_phase_timing(
                        [
                            {
                                "included": True,
                                "wall_ns": 120,
                                "phase_traces": [
                                    {
                                        "path": "runner.jsonl",
                                        "line": index,
                                        "value": row,
                                        "read_error": None,
                                    }
                                    for index, row in enumerate(rows, 1)
                                ],
                            }
                        ]
                    )

    def test_missing_incomplete_and_accounting_are_eligibility_failures(self) -> None:
        rows = self._e2e_rows()[:-1]
        classified = self._classify(rows)
        self.assertFalse(classified.hard_errors)
        self.assertTrue(
            any("missing its final" in error for error in classified.eligibility_errors)
        )

        rows = self._e2e_rows()
        rows[4].update(
            complete=False, outcome="timeout", exit_code=None
        )
        classified = self._classify(rows)
        self.assertFalse(classified.hard_errors)
        self.assertTrue(
            any("incomplete" in error for error in classified.eligibility_errors)
        )

        rows = self._e2e_rows()
        rows[6]["duration_ns"] += 1
        classified = self._classify(rows)
        self.assertFalse(classified.hard_errors)
        self.assertTrue(
            any("accounting mismatch" in error for error in classified.eligibility_errors)
        )

    def test_runner_total_must_fit_job_wall(self) -> None:
        classified = self._classify(self._e2e_rows(), wall_ns=112)
        self.assertTrue(
            any("exceeds job wall" in error for error in classified.eligibility_errors)
        )

    def test_runner_summary_is_per_lane_and_retains_accounting_axes(self) -> None:
        rows = self._e2e_rows()
        record = {
            "included": True,
            "wall_ns": 120,
            "phase_traces": [
                {
                    "path": "runner.jsonl",
                    "line": index,
                    "value": row,
                    "read_error": None,
                }
                for index, row in enumerate(rows, 1)
            ],
        }
        summary = harness._summarize_runner_phase_timing([record])
        assert summary is not None
        self.assertEqual(summary["sample_count"], 1)
        self.assertEqual(summary["compiler_construction"]["duration_ns"]["median"], 60)
        self.assertEqual(summary["runner_total_ns"]["median"], 113)
        self.assertEqual(summary["outside_runner_wall_ns"]["median"], 7)
        self.assertEqual(
            summary["accounting"]["suites"]["e2e"]["balance_ns"]["median"],
            0,
        )
        self.assertEqual(
            summary["accounting"]["runner"]["balance_ns"]["median"], 0
        )
        self.assertTrue(
            any(
                item["stage"] == "vorton_check"
                and item["command_category"] == "vorton"
                and item["suite"] == "e2e"
                for item in summary["stage_category_suite"]
            )
        )


_PHASE_TEST_COMPILER = os.environ.get("VORTON_PHASE_TEST_COMPILER", "")
_PHASE_TEST_COMPILER_SHA256 = os.environ.get(
    "VORTON_PHASE_TEST_COMPILER_SHA256", ""
)


@unittest.skipUnless(
    _PHASE_TEST_COMPILER
    and _PHASE_TEST_COMPILER_SHA256
    and Path(_PHASE_TEST_COMPILER).is_file(),
    "set exact VORTON_PHASE_TEST_COMPILER and SHA256 to run native phase-timing parity",
)
class NativeCliPhaseTimingTests(unittest.TestCase):
    def test_candidate_identity_is_explicit_and_exact(self) -> None:
        self.assertRegex(_PHASE_TEST_COMPILER_SHA256, r"^[0-9a-f]{64}$")
        self.assertEqual(
            harness._sha256_file(Path(_PHASE_TEST_COMPILER)),
            _PHASE_TEST_COMPILER_SHA256,
        )

    def test_timed_and_untimed_cli_contract_matrix(self) -> None:
        compiler = str(Path(_PHASE_TEST_COMPILER).resolve())
        command_only = ["command_total"]
        single_parse = ["input_entry_load", "entry_parse", "command_total"]
        single_checked = [
            "input_entry_load",
            "entry_parse",
            "type_effect_check_lower",
            "command_total",
        ]
        project_parse = [
            "input_entry_load",
            "entry_parse",
            "project_module_load_parse",
            "command_total",
        ]
        project_checked = [
            "input_entry_load",
            "entry_parse",
            "project_module_load_parse",
            "type_effect_check_lower",
            "command_total",
        ]
        rc_checked = [
            "input_entry_load",
            "entry_parse",
            "type_effect_check_lower",
            "resource_plan_verify",
            "command_total",
        ]
        single_built = [
            "input_entry_load",
            "entry_parse",
            "type_effect_check_lower",
            "resource_plan_verify",
            "command_total",
        ]
        project_built = [
            "input_entry_load",
            "entry_parse",
            "project_module_load_parse",
            "type_effect_check_lower",
            "resource_plan_verify",
            "command_total",
        ]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            parse_project = root / "parse-project"
            type_project = root / "type-project"
            parse_project.mkdir()
            type_project.mkdir()
            main_source = (
                "use lib::value\n\n"
                "fn main() {\n"
                "    print(value())\n"
                "}\n"
            )
            (parse_project / "main.vorton").write_text(main_source, encoding="utf-8")
            (parse_project / "lib.vorton").write_text(
                "pub fn value( {\n", encoding="utf-8"
            )
            (type_project / "main.vorton").write_text(main_source, encoding="utf-8")
            (type_project / "lib.vorton").write_text(
                'pub fn value() -> Int { "bad" }\n', encoding="utf-8"
            )
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            fake_source = root / "fake-clang.c"
            fake_source.write_text("int main(void) { return 7; }\n", encoding="utf-8")
            real_clang = shutil.which("clang")
            assert real_clang is not None
            subprocess.run(
                [real_clang, str(fake_source), "-o", str(fake_bin / "clang.exe")],
                check=True,
                capture_output=True,
                timeout=60,
            )
            output_dirs = {
                name: root / name
                for name in (
                    "single-build-success", "single-build-failure",
                    "project-build-success", "project-build-failure",
                )
            }
            for directory in output_dirs.values():
                directory.mkdir()
            cases = [
                ("help_success", ["help"], 0, command_only, False),
                ("lsp_failure", ["lsp"], 1, command_only, False),
                (
                    "single_success",
                    ["check", str(harness.REPO_ROOT / "tests/cases/hello.vorton")],
                    0,
                    single_checked,
                    False,
                ),
                (
                    "single_parse_failure",
                    ["check", str(harness.REPO_ROOT / "tests/cases/error_multi_parse.vorton")],
                    1,
                    single_parse,
                    False,
                ),
                (
                    "single_type_failure",
                    ["check", str(harness.REPO_ROOT / "tests/cases/error_undefined.vorton")],
                    1,
                    single_checked,
                    False,
                ),
                (
                    "project_success",
                    [
                        "check",
                        str(
                            harness.REPO_ROOT
                            / "tests/cases/modules/diamond_dep/main.vorton"
                        ),
                    ],
                    0,
                    project_checked,
                    False,
                ),
                (
                    "project_parse_failure",
                    ["check", str(parse_project / "main.vorton")],
                    1,
                    project_parse,
                    False,
                ),
                (
                    "project_type_failure",
                    ["check", str(type_project / "main.vorton")],
                    1,
                    project_checked,
                    False,
                ),
                (
                    "rc_success",
                    [
                        "check",
                        str(
                            harness.REPO_ROOT
                            / "tests/cases/verify_rc/option_temp_leak.vorton"
                        ),
                        "--verify-rc",
                    ],
                    0,
                    rc_checked,
                    False,
                ),
                (
                    "rc_fatal",
                    [
                        "check",
                        str(
                            harness.REPO_ROOT
                            / "tests/cases/verify_rc/option_temp_leak.vorton"
                        ),
                        "--verify-rc",
                        "--rc-mutate=skip-anf",
                    ],
                    1,
                    rc_checked,
                    False,
                ),
                (
                    "single_build_success",
                    [
                        "build",
                        str(harness.REPO_ROOT / "tests/cases/hello.vorton"),
                        f"--out-dir={output_dirs['single-build-success']}",
                    ],
                    0,
                    single_built,
                    False,
                ),
                (
                    "single_build_clang_failure",
                    [
                        "build",
                        str(harness.REPO_ROOT / "tests/cases/hello.vorton"),
                        f"--out-dir={output_dirs['single-build-failure']}",
                    ],
                    1,
                    single_built,
                    True,
                ),
                (
                    "project_build_success",
                    [
                        "build",
                        str(harness.REPO_ROOT / "tests/cases/modules/diamond_dep/main.vorton"),
                        f"--out-dir={output_dirs['project-build-success']}",
                    ],
                    0,
                    project_built,
                    False,
                ),
                (
                    "project_build_clang_failure",
                    [
                        "build",
                        str(harness.REPO_ROOT / "tests/cases/modules/diamond_dep/main.vorton"),
                        f"--out-dir={output_dirs['project-build-failure']}",
                    ],
                    1,
                    project_built,
                    True,
                ),
            ]
            for name, argv, expected_exit, expected_executed, force_clang_failure in cases:
                with self.subTest(case=name):
                    child_env = dict(os.environ)
                    if force_clang_failure:
                        child_env["PATH"] = str(fake_bin) + os.pathsep + child_env["PATH"]
                    untimed = subprocess.run(
                        [compiler, *argv],
                        cwd=harness.REPO_ROOT,
                        env=child_env,
                        capture_output=True,
                        timeout=120,
                        check=False,
                    )
                    trace = root / f"{name}.jsonl"
                    timed = subprocess.run(
                        [
                            compiler,
                            *argv,
                            f"--phase-timing={trace}",
                            f"--phase-timing-lane={name}",
                            "--phase-timing-compiler=native-matrix",
                            "--phase-timing-source=native-matrix-source",
                        ],
                        cwd=harness.REPO_ROOT,
                        env=child_env,
                        capture_output=True,
                        timeout=120,
                        check=False,
                    )
                    self.assertEqual(untimed.returncode, expected_exit)
                    self.assertEqual(timed.returncode, untimed.returncode)
                    self.assertEqual(timed.stdout, untimed.stdout)
                    self.assertEqual(timed.stderr, untimed.stderr)
                    rows = [
                        json.loads(line)
                        for line in trace.read_text(encoding="utf-8").splitlines()
                    ]
                    self.assertEqual(len(rows), len(harness.COMPILER_PHASE_ORDER))
                    self.assertEqual(
                        [row["phase"] for row in rows],
                        list(harness.COMPILER_PHASE_ORDER),
                    )
                    required = {
                        "schema",
                        "schema_version",
                        "lane",
                        "phase",
                        "duration_ns",
                        "unit",
                        "compiler_identity",
                        "source_identity",
                        "entry_file",
                        "executed",
                        "complete",
                        "command_success",
                    }
                    for row in rows:
                        self.assertEqual(set(row), required)
                        self.assertEqual(row["schema"], harness.COMPILER_PHASE_SCHEMA)
                        self.assertEqual(row["schema_version"], 1)
                        self.assertEqual(row["lane"], name)
                        self.assertEqual(row["compiler_identity"], "native-matrix")
                        self.assertEqual(row["source_identity"], "native-matrix-source")
                        self.assertEqual(row["unit"], "ns")
                        self.assertIs(type(row["duration_ns"]), int)
                        self.assertGreaterEqual(row["duration_ns"], 0)
                        self.assertTrue(row["complete"])
                        self.assertEqual(
                            row["command_success"], expected_exit == 0
                        )
                    actual_executed = [
                        row["phase"] for row in rows if row["executed"]
                    ]
                    self.assertEqual(actual_executed, expected_executed)
                    self.assertTrue(
                        all(
                            row["duration_ns"] == 0
                            for row in rows
                            if not row["executed"]
                        )
                    )
                    errors = phase_errors(harness._classify_compiler_phase_rows(
                        rows,
                        expected_lane=name,
                        expected_compiler_identity="native-matrix",
                        expected_source_identity="native-matrix-source",
                        expected_entry_file=(
                            str(Path(argv[1]).resolve())
                            if "input_entry_load" in expected_executed
                            else ""
                        ),
                        expected_success=expected_exit == 0,
                        expected_executed_phases=expected_executed,
                        wall_ns=harness.VORTON_INT_MAX,
                    ))
                    self.assertEqual(errors, [])


@unittest.skipUnless(os.name == "nt", "Windows Job Object tests require Windows")
class WindowsJobTests(unittest.TestCase):
    def test_preflight_and_invocations_do_not_leak_job_handles(self) -> None:
        evidence = preflight_job_support()
        self.assertEqual(evidence["handle_count_before"], evidence["handle_count_after"])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            # CPython initializes two process-global synchronization handles on
            # its first low-level CreateProcess call.  Warm that one-time state,
            # then require steady-state handle equality.
            run_in_job(
                [sys.executable, "-c", "pass"],
                cwd=Path.cwd(),
                env=os.environ,
                stdout_path=root / "warmup-stdout.txt",
                stderr_path=root / "warmup-stderr.txt",
                timeout_seconds=5,
            )
            before = current_process_handle_count()
            with mock.patch.object(
                windows_job, "_new_job", wraps=windows_job._new_job
            ) as new_job:
                result = run_in_job(
                    [sys.executable, "-c", "pass"],
                    cwd=Path.cwd(),
                    env=os.environ,
                    stdout_path=root / "stdout.txt",
                    stderr_path=root / "stderr.txt",
                    timeout_seconds=5,
                )
            self.assertEqual(result["exit_code"], 0)
            self.assertEqual(new_job.call_count, 1)
            self.assertIsNone(result["max_worker_peak_rss_bytes"])
            self.assertEqual(current_process_handle_count(), before)

    def test_process_tree_metrics_and_separate_streams(self) -> None:
        preflight_job_support()
        child_code = (
            "import subprocess,sys; "
            "print('root-out'); print('root-err', file=sys.stderr); "
            "p=subprocess.Popen([sys.executable,'-c',"
            "\"import sys,time; print('child-out'); "
            "print('child-err',file=sys.stderr); time.sleep(0.08)\"]); p.wait()"
        )
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stdout = root / "stdout.txt"
            stderr = root / "stderr.txt"
            result = run_in_job(
                [sys.executable, "-c", child_code],
                cwd=Path.cwd(),
                env=os.environ,
                stdout_path=stdout,
                stderr_path=stderr,
                timeout_seconds=5,
            )
            self.assertEqual(result["exit_code"], 0)
            self.assertGreaterEqual(result["process_count"]["total"], 2)
            self.assertGreaterEqual(result["rss_observed_process_count"], 2)
            self.assertTrue(result["rss_complete"])
            self.assertGreater(result["peak_job_commit_bytes"], 0)
            self.assertGreater(result["peak_root_rss_bytes"], 0)
            self.assertGreater(result["sampled_peak_tree_rss_bytes"], 0)
            self.assertGreater(result["max_worker_peak_rss_bytes"], 0)
            self.assertIn("root-out", stdout.read_text(encoding="utf-8"))
            self.assertIn("child-out", stdout.read_text(encoding="utf-8"))
            self.assertIn("root-err", stderr.read_text(encoding="utf-8"))
            self.assertIn("child-err", stderr.read_text(encoding="utf-8"))

    def test_timeout_terminates_the_job(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            result = run_in_job(
                [sys.executable, "-c", "import time; time.sleep(2)"],
                cwd=Path.cwd(),
                env=os.environ,
                stdout_path=root / "stdout.txt",
                stderr_path=root / "stderr.txt",
                timeout_seconds=0.05,
            )
            self.assertTrue(result["timed_out"])
            self.assertNotEqual(result["exit_code"], 0)


if __name__ == "__main__":
    unittest.main()
