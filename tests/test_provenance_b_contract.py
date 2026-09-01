import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

import run_tests as runner


def coff_object(
    *, timestamp: int = 0x01020304, machine: int = 0x8664,
    section_count: int = 3, length: int = 64,
) -> bytes:
    data = bytearray(length)
    if length >= 2:
        data[0:2] = machine.to_bytes(2, "little")
    if length >= 4:
        data[2:4] = section_count.to_bytes(2, "little")
    if length >= 8:
        data[4:8] = timestamp.to_bytes(4, "little")
    return bytes(data)


class ProvenanceBContractTests(unittest.TestCase):
    def test_registered_source_and_mutation_inventory(self) -> None:
        self.assertEqual(runner.identity_checkpoint_source_errors(), [])

    def test_runtime_fixture_receipt_is_exact(self) -> None:
        expected = (
            runner.REPO
            / "tests"
            / "cases"
            / "provenance_b_capture_identity.expected"
        ).read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            expected, ["15", "15", "true", "7", "12", "true"])

    def test_rejected_f_analyzer_api_is_absent(self) -> None:
        for name in (
            "parse_c_function_provenance_facts",
            "analyze_two_level_provenance_c",
            "_parse_uniform_closure_call_statement",
        ):
            self.assertFalse(hasattr(runner, name), name)

    def test_coff_timestamp_only_difference_is_equal_without_mutation(self) -> None:
        left = coff_object(timestamp=0x01020304)
        right = coff_object(timestamp=0xA1B2C3D4)
        left_before = bytes(left)
        right_before = bytes(right)
        self.assertEqual(
            runner.coff_object_timestamp_equality_errors(
                "timestamp-only", left, right),
            [],
        )
        self.assertEqual(left, left_before)
        self.assertEqual(right, right_before)

    def test_coff_difference_outside_timestamp_fails(self) -> None:
        left = coff_object()
        changed = bytearray(left)
        changed[8] = 1
        errors = runner.coff_object_timestamp_equality_errors(
            "offset-eight", left, bytes(changed))
        self.assertTrue(any("diff outside timestamp" in error for error in errors))

    def test_coff_wrong_machine_fails_as_invalid(self) -> None:
        errors = runner.coff_object_timestamp_equality_errors(
            "wrong-machine", coff_object(machine=0x014C), coff_object())
        self.assertTrue(any("invalid COFF" in error for error in errors))

    def test_coff_length_and_section_count_fail_as_invalid(self) -> None:
        for label, left, right in (
            ("short", coff_object(length=19), coff_object(length=19)),
            ("length", coff_object(length=64), coff_object(length=65)),
            ("zero-sections", coff_object(section_count=0), coff_object()),
            ("too-many-sections", coff_object(section_count=97), coff_object()),
        ):
            with self.subTest(label=label):
                errors = runner.coff_object_timestamp_equality_errors(
                    label, left, right)
                self.assertTrue(
                    any("invalid COFF" in error for error in errors), errors)

    def test_evidence_root_is_exact_empty_persistent_authority(self) -> None:
        with tempfile.TemporaryDirectory() as sandbox:
            sandbox_path = Path(sandbox).resolve()
            evidence_root = sandbox_path / "persistent" / "evidence"
            evidence_root.mkdir(parents=True)
            fake_system_temp = sandbox_path / "system-temp"
            fake_system_temp.mkdir()
            with (
                mock.patch.object(
                    runner.tempfile, "gettempdir", return_value=str(fake_system_temp)),
                mock.patch.dict(
                    os.environ,
                    {runner.IDENTITY_EVIDENCE_ROOT_ENV: str(evidence_root)},
                    clear=False,
                ),
            ):
                resolved, error = runner.identity_checkpoint_evidence_root()
                self.assertEqual(resolved, evidence_root)
                self.assertIsNone(error)
                (evidence_root / "residue").write_bytes(b"retained")
                resolved, error = runner.identity_checkpoint_evidence_root()
                self.assertIsNone(resolved)
                self.assertIn("initially empty", error or "")

    def test_missing_evidence_root_stops_before_candidate_call(self) -> None:
        candidate_gate = mock.Mock(side_effect=AssertionError("candidate invoked"))
        with (
            mock.patch.dict(os.environ, {}, clear=True),
            mock.patch.object(runner, "identity_checkpoint_source_errors", return_value=[]),
            mock.patch.object(
                runner,
                "identity_checkpoint_candidate_identity",
                return_value=(str(Path(sys.executable).resolve()), "a" * 64, None),
            ),
            mock.patch.object(
                runner, "callable_identity_generated_c_errors", candidate_gate),
        ):
            errors, detail = runner.identity_checkpoint_errors()
        self.assertEqual(
            errors,
            [f"{runner.IDENTITY_EVIDENCE_ROOT_ENV} is required with candidate"],
        )
        self.assertIn("VORTON_IDENTITY_EVIDENCE_ROOT=invalid", detail)
        candidate_gate.assert_not_called()

    def test_invalid_evidence_root_stops_before_candidate_call(self) -> None:
        candidate_gate = mock.Mock(side_effect=AssertionError("candidate invoked"))
        with (
            mock.patch.dict(
                os.environ,
                {runner.IDENTITY_EVIDENCE_ROOT_ENV: "relative/evidence"},
                clear=True,
            ),
            mock.patch.object(runner, "identity_checkpoint_source_errors", return_value=[]),
            mock.patch.object(
                runner,
                "identity_checkpoint_candidate_identity",
                return_value=(str(Path(sys.executable).resolve()), "b" * 64, None),
            ),
            mock.patch.object(
                runner, "callable_identity_generated_c_errors", candidate_gate),
        ):
            errors, _detail = runner.identity_checkpoint_errors()
        self.assertEqual(
            errors,
            [f"{runner.IDENTITY_EVIDENCE_ROOT_ENV} must be an absolute path"],
        )
        candidate_gate.assert_not_called()

    def test_child_failure_retains_raw_audit_and_archive(self) -> None:
        def failed_child(spec, *, result_validator=None):
            self.assertIsNotNone(result_validator)
            (spec.evidence_dir / "stdout.raw").write_bytes(b"partial stdout")
            (spec.evidence_dir / "stderr.raw").write_bytes(b"unique child failure")
            return {"status": "failure", "classification": "exit-nonzero"}

        def exclusive_archive(_source: Path, target: Path):
            with target.open("xb") as handle:
                handle.write(b"durable archive")
            return {"file_count": 2}

        with tempfile.TemporaryDirectory() as sandbox:
            case_root = Path(sandbox) / "off"
            case_root.mkdir()
            evidence_log: list[str] = []
            with (
                mock.patch.object(runner, "_resolved_executable", return_value=sys.executable),
                mock.patch.object(runner, "_controlled_environment", return_value={}),
                mock.patch.object(runner, "run_one_shot", side_effect=failed_child),
                mock.patch.object(
                    runner,
                    "audit_one_shot_attempt",
                    return_value={"state": "complete", "status": "failure"},
                ),
                mock.patch.object(
                    runner, "create_one_shot_archive", side_effect=exclusive_archive),
            ):
                artifacts, error = runner.run_identity_candidate_mode(
                    sys.executable,
                    "tests/cases/provenance_b_capture_identity.vorton",
                    case_root,
                    evidence_log,
                    ledger=False,
                )
            self.assertIsNone(artifacts)
            self.assertIn("exit-nonzero", error or "")
            self.assertTrue((case_root / "one-shot" / "stderr.raw").is_file())
            self.assertEqual(
                (case_root / "one-shot" / "stderr.raw").read_bytes(),
                b"unique child failure",
            )
            self.assertTrue((Path(sandbox) / "off.tar").is_file())
            self.assertIn(str(case_root / "one-shot"), error or "")
            self.assertIn(str(Path(sandbox) / "off.tar"), error or "")
            self.assertEqual(len(evidence_log), 1)

    def test_later_comparison_failure_retains_all_case_evidence(self) -> None:
        def completed_mode(
            _vorton_exe: str,
            _fixture: str,
            case_root: Path,
            evidence_log: list[str],
            *,
            ledger: bool,
        ):
            evidence_dir = case_root / "one-shot"
            evidence_dir.mkdir()
            (evidence_dir / "stdout.raw").write_bytes(b"raw")
            archive_path = case_root.parent / f"{case_root.name}.tar"
            archive_path.write_bytes(b"archive")
            archive_hash = runner._sha256_file(archive_path)
            evidence_log.append(
                f"{case_root.name}:raw={evidence_dir};archive={archive_path};"
                f"sha256={archive_hash}")
            stdout = (
                b"Compiled: " + os.fsencode(str(case_root.resolve()))
                + b"/out/provenance.o\n"
            )
            c_bytes = b"off-C" if case_root.name == "off" else b"on-C"
            return runner.IdentityCandidateArtifacts(
                mode="on" if ledger else "off",
                case_root=case_root,
                stdout=stdout,
                stderr=b"",
                c_bytes=c_bytes,
                object_bytes=coff_object(),
                ledger_bytes=(b"VORTON-C-IDENTITY-LEDGER|1\n" if ledger else None),
                verdict={"status": "success"},
                audit={"state": "complete", "status": "success"},
                archive_path=archive_path,
                archive_sha256=archive_hash,
            ), None

        with tempfile.TemporaryDirectory() as sandbox:
            evidence_root = Path(sandbox)
            evidence_log: list[str] = []
            with mock.patch.object(
                runner, "run_identity_candidate_mode", side_effect=completed_mode
            ):
                errors = runner.callable_identity_generated_c_errors(
                    sys.executable, evidence_root, evidence_log)
            self.assertIn("identity ledger changed off/on1 C bytes", errors)
            for case_name in ("off", "on1", "on2"):
                self.assertTrue(
                    (evidence_root / case_name / "one-shot" / "stdout.raw").is_file())
                self.assertTrue((evidence_root / f"{case_name}.tar").is_file())
            self.assertEqual(len(evidence_log), 3)


if __name__ == "__main__":
    unittest.main()
