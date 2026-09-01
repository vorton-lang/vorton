import argparse
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PureWindowsPath
from unittest.mock import patch


TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

import run_tests as runner


class PhaseTimingTests(unittest.TestCase):
    def setUp(self) -> None:
        runner._PHASE_TRACER = None

    def tearDown(self) -> None:
        runner._PHASE_TRACER = None

    @staticmethod
    def read_records(path: Path):
        return [
            json.loads(line)
            for line in path.read_text(encoding="utf-8").splitlines()
        ]

    def test_default_mode_does_not_construct_trace_or_read_clock(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            absent_trace = Path(temp_dir) / "not-created.jsonl"
            runtime_cpp = Path(temp_dir) / "vorton_runtime.cpp"
            runtime_o = Path(temp_dir) / "vorton_runtime.o"
            runtime_cpp.write_text("runtime", encoding="utf-8")
            runtime_o.write_bytes(b"object")
            os.utime(runtime_cpp, (10, 10))
            os.utime(runtime_o, (20, 20))
            completed = subprocess.CompletedProcess(["vorton", "check"], 0, "", "")
            with (
                patch.object(sys, "argv", ["run_tests.py", "--suite", "parity"]),
                patch.object(runner, "_run_selected", return_value=0),
                patch.object(runner, "PhaseTimingTrace") as trace_class,
                patch.object(runner.time, "perf_counter_ns") as clock,
                patch.object(runner.subprocess, "run", return_value=completed),
                patch.object(runner, "RUNTIME_CPP", runtime_cpp),
                patch.object(runner, "RUNTIME_O", runtime_o),
            ):
                self.assertEqual(runner.main(), 0)
                result = runner.vorton_check("vorton", "case.vorton")
                self.assertTrue(runner.ensure_runtime("clang"))

            self.assertEqual(result.returncode, 0)
            trace_class.assert_not_called()
            clock.assert_not_called()
            self.assertFalse(absent_trace.exists())

    def test_child_classification_sequence_schema_and_partial_flush(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            trace_path = Path(temp_dir) / "child.jsonl"
            success = subprocess.CompletedProcess(["vorton", "check"], 0, "", "")
            nonzero = subprocess.CompletedProcess(["vorton", "build"], 7, "", "")
            timeout = subprocess.TimeoutExpired(["program.exe"], 30)
            with (
                patch.object(
                    runner.time,
                    "perf_counter_ns",
                    side_effect=[0, 10, 20, 30, 50, 60, 90],
                ),
                patch.object(
                    runner.subprocess, "run",
                    side_effect=[success, nonzero, timeout],
                ),
            ):
                tracer = runner.PhaseTimingTrace(str(trace_path))
                runner._PHASE_TRACER = tracer
                runner._run_subprocess(
                    "vorton_check", ["vorton", "check", "a.vorton"],
                    phase_suite="e2e", phase_case="a.vorton",
                )
                runner._run_subprocess(
                    "vorton_build", ["vorton", "build", "b.vorton"],
                    phase_suite="e2e", phase_case="b.vorton",
                )
                with self.assertRaises(subprocess.TimeoutExpired):
                    runner._run_subprocess(
                        "run_exe", ["program.exe"],
                        phase_suite="e2e", phase_case="c.vorton",
                    )

                # Every record is flushed before control returns to the runner,
                # including the timeout path.
                records = self.read_records(trace_path)
                tracer.close()

            self.assertEqual([row["sequence"] for row in records], [1, 2, 3])
            self.assertEqual([row["duration_ns"] for row in records], [10, 20, 30])
            self.assertEqual(
                [(row["outcome"], row["complete"], row["exit_code"])
                 for row in records],
                [("success", True, 0), ("nonzero", True, 7),
                 ("timeout", False, None)],
            )
            self.assertEqual([row["case"] for row in records],
                             ["a.vorton", "b.vorton", "c.vorton"])
            for row in records:
                self.assertEqual(set(row), runner.PHASE_TIMING_FIELDS)
                self.assertEqual(row["schema"], runner.PHASE_TIMING_SCHEMA)
                self.assertEqual(row["version"], runner.PHASE_TIMING_VERSION)
                self.assertTrue(row["executed"])

    def test_suite_and_runner_totals_partition_residual(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            trace_path = Path(temp_dir) / "accounting.jsonl"
            child = subprocess.CompletedProcess(["vorton"], 0, "", "")
            with (
                patch.object(
                    runner.time,
                    "perf_counter_ns",
                    side_effect=[0, 10, 20, 30, 40, 60, 100, 150],
                ),
                patch.object(runner.subprocess, "run", return_value=child),
            ):
                tracer = runner.PhaseTimingTrace(str(trace_path))
                runner._PHASE_TRACER = tracer

                def run_children() -> None:
                    runner._run_subprocess(
                        "vorton_check", ["vorton"], phase_case="first",
                    )
                    runner._run_subprocess(
                        "vorton_build", ["vorton"], phase_case="second",
                    )

                tracer.run_suite("parity", run_children)
                tracer.finish(complete=True, outcome="success", exit_code=0)
                tracer.close()

            records = self.read_records(trace_path)
            self.assertEqual([row["sequence"] for row in records],
                             list(range(1, 7)))
            suite_rows = [row for row in records if row["suite"] == "parity"]
            children = [row for row in suite_rows
                        if row["stage"] in {"vorton_check", "vorton_build"}]
            suite_residual = next(
                row for row in suite_rows
                if row["stage"] == "orchestration_residual"
            )
            suite_total = next(
                row for row in suite_rows if row["stage"] == "suite_total"
            )
            self.assertEqual(sum(row["duration_ns"] for row in children), 30)
            self.assertEqual(suite_residual["duration_ns"], 60)
            self.assertEqual(suite_total["duration_ns"], 90)
            self.assertEqual(
                sum(row["duration_ns"] for row in children)
                + suite_residual["duration_ns"],
                suite_total["duration_ns"],
            )

            runner_residual = next(
                row for row in records
                if row["suite"] is None
                and row["stage"] == "orchestration_residual"
            )
            runner_total = next(
                row for row in records if row["stage"] == "runner_total"
            )
            self.assertEqual(runner_residual["duration_ns"], 60)
            self.assertEqual(runner_total["duration_ns"], 150)
            self.assertEqual(
                suite_total["duration_ns"] + runner_residual["duration_ns"],
                runner_total["duration_ns"],
            )

    def test_unhandled_suite_exception_keeps_incomplete_partial_trace(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            trace_path = Path(temp_dir) / "partial.jsonl"
            child = subprocess.CompletedProcess(["vorton"], 0, "", "")
            with (
                patch.object(
                    runner.time, "perf_counter_ns",
                    side_effect=[0, 10, 20, 30, 50, 80],
                ),
                patch.object(runner.subprocess, "run", return_value=child),
            ):
                tracer = runner.PhaseTimingTrace(str(trace_path))
                runner._PHASE_TRACER = tracer

                def fail_after_child() -> None:
                    runner._run_subprocess(
                        "vorton_check", ["vorton"], phase_case="partial-case",
                    )
                    raise RuntimeError("fixture failure")

                with self.assertRaisesRegex(RuntimeError, "fixture failure"):
                    tracer.run_suite("e2e", fail_after_child)
                tracer.finish(complete=False, outcome="exception", exit_code=None)
                records_before_close = self.read_records(trace_path)
                tracer.close()

            suite_total = next(
                row for row in records_before_close
                if row["suite"] == "e2e" and row["stage"] == "suite_total"
            )
            runner_total = next(
                row for row in records_before_close
                if row["stage"] == "runner_total"
            )
            self.assertFalse(suite_total["complete"])
            self.assertEqual(suite_total["outcome"], "exception")
            self.assertFalse(runner_total["complete"])

    def test_phase_timing_path_must_be_absolute(self) -> None:
        with self.assertRaises(argparse.ArgumentTypeError):
            runner._phase_timing_path("relative.jsonl")

    def test_production_relative_case_identity_uses_forward_slashes(self) -> None:
        relative = PureWindowsPath("negative", "join_non_str.vorton")
        self.assertEqual(
            runner._phase_relative_identity(relative),
            "negative/join_non_str.vorton",
        )
        self.assertEqual(
            runner._phase_relative_identity(relative, "neg:"),
            "neg:negative/join_non_str.vorton",
        )

    def test_runtime_prepare_cache_hit_is_explicit_non_child(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            runtime_cpp = temp_root / "vorton_runtime.cpp"
            runtime_o = temp_root / "vorton_runtime.o"
            trace_path = temp_root / "cached.jsonl"
            runtime_cpp.write_text("runtime", encoding="utf-8")
            runtime_o.write_bytes(b"object")
            os.utime(runtime_cpp, (10, 10))
            os.utime(runtime_o, (20, 20))
            with (
                patch.object(runner, "RUNTIME_CPP", runtime_cpp),
                patch.object(runner, "RUNTIME_O", runtime_o),
                patch.object(
                    runner.time, "perf_counter_ns", side_effect=[0, 10, 25],
                ),
                patch.object(runner.subprocess, "run") as child_run,
            ):
                tracer = runner.PhaseTimingTrace(str(trace_path))
                runner._PHASE_TRACER = tracer
                self.assertTrue(runner.ensure_runtime("clang"))
                records = self.read_records(trace_path)
                tracer.close()

            child_run.assert_not_called()
            self.assertEqual(len(records), 1)
            record = records[0]
            self.assertEqual(set(record), runner.PHASE_TIMING_FIELDS)
            self.assertEqual(record["stage"], "runtime_prepare")
            self.assertEqual(record["duration_ns"], 15)
            self.assertFalse(record["executed"])
            self.assertTrue(record["complete"])
            self.assertEqual(record["outcome"], "cached")
            self.assertIsNone(record["exit_code"])
            self.assertIsNone(record["command_category"])

    def test_runtime_prepare_rebuild_records_real_child(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            runtime_cpp = temp_root / "vorton_runtime.cpp"
            runtime_o = temp_root / "vorton_runtime.o"
            trace_path = temp_root / "rebuilt.jsonl"
            runtime_cpp.write_text("runtime", encoding="utf-8")

            def compile_runtime(command, **kwargs):
                runtime_o.write_bytes(b"object")
                return subprocess.CompletedProcess(command, 0, b"", b"")

            with (
                patch.object(runner, "RUNTIME_CPP", runtime_cpp),
                patch.object(runner, "RUNTIME_O", runtime_o),
                patch.object(runner.shutil, "which", return_value="clang++"),
                patch.object(
                    runner.time, "perf_counter_ns",
                    side_effect=[0, 10, 20, 50],
                ),
                patch.object(
                    runner.subprocess, "run", side_effect=compile_runtime,
                ) as child_run,
            ):
                tracer = runner.PhaseTimingTrace(str(trace_path))
                runner._PHASE_TRACER = tracer
                self.assertTrue(runner.ensure_runtime("clang"))
                records = self.read_records(trace_path)
                tracer.close()

            child_run.assert_called_once()
            self.assertEqual(len(records), 1)
            record = records[0]
            self.assertEqual(set(record), runner.PHASE_TIMING_FIELDS)
            self.assertEqual(record["stage"], "runtime_prepare")
            self.assertEqual(record["duration_ns"], 30)
            self.assertTrue(record["executed"])
            self.assertTrue(record["complete"])
            self.assertEqual(record["outcome"], "success")
            self.assertEqual(record["exit_code"], 0)
            self.assertEqual(record["command_category"], "clang")


if __name__ == "__main__":
    unittest.main()
