import hashlib
import os
import shutil
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch


TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

import run_tests as runner


class IdentityCheckpointRunnerTests(unittest.TestCase):
    def fresh_persistent_evidence_root(self, label: str) -> Path:
        base = (
            runner.REPO / "bench" / "check" / "results"
            / "identity-checkpoint-runner-units"
        )
        base.mkdir(parents=True, exist_ok=True)
        root = base / f"{label}-{uuid.uuid4().hex}"
        root.mkdir(parents=False, exist_ok=False)
        self.addCleanup(shutil.rmtree, root, True)
        resolved = root.resolve(strict=True)
        self.assertTrue(resolved.is_absolute())
        self.assertEqual(list(resolved.iterdir()), [])
        return resolved

    def test_candidate_case_roots_are_distinct_exclusive_directories(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            parent = Path(tmpdir)
            default_root = runner.identity_candidate_case_root(
                parent, "default-body")
            provenance_root = runner.identity_candidate_case_root(
                parent, "provenance-b")

            self.assertTrue(default_root.is_dir())
            self.assertTrue(provenance_root.is_dir())
            self.assertNotEqual(default_root, provenance_root)
            with self.assertRaisesRegex(
                RuntimeError, "cannot create identity candidate case root"
            ):
                runner.identity_candidate_case_root(parent, "default-body")

    def test_unset_candidate_runs_source_oracle_only(self) -> None:
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(
                runner, "identity_checkpoint_source_errors", return_value=[]
            ) as source_oracle,
            patch.object(
                runner, "callable_identity_generated_c_errors"
            ) as generated_oracle,
        ):
            errors, detail = runner.identity_checkpoint_errors()

        self.assertEqual(errors, [])
        self.assertIn("source/mutation only", detail)
        source_oracle.assert_called_once_with()
        generated_oracle.assert_not_called()

    def test_set_candidate_invokes_exact_hashed_executable(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            candidate = Path(tmpdir) / "candidate vorton.exe"
            candidate_bytes = b"exact I-prime candidate"
            candidate.write_bytes(candidate_bytes)
            resolved = str(candidate.resolve(strict=True))
            expected_hash = hashlib.sha256(candidate_bytes).hexdigest()
            evidence_root = self.fresh_persistent_evidence_root("exact")
            events = []

            def generate_candidate(
                path: str, root: Path, evidence_log: list[str],
            ) -> list[str]:
                self.assertEqual(path, resolved)
                self.assertEqual(root, evidence_root)
                evidence_log.append("generated retained")
                events.append("generated-c")
                return []

            with (
                patch.dict(
                    os.environ,
                    {
                        runner.IDENTITY_CANDIDATE_ENV: resolved,
                        runner.IDENTITY_EVIDENCE_ROOT_ENV: str(evidence_root),
                    },
                    clear=True,
                ),
                patch.object(
                    runner, "identity_checkpoint_source_errors", return_value=[]
                ) as source_oracle,
                patch.object(
                    runner, "callable_identity_generated_c_errors",
                    side_effect=generate_candidate,
                ) as generated_oracle,
            ):
                errors, detail = runner.identity_checkpoint_errors()

        self.assertEqual(errors, [])
        self.assertIn(f"candidate={resolved}", detail)
        self.assertIn(f"sha256={expected_hash}", detail)
        self.assertIn(f"evidence_root={evidence_root}", detail)
        self.assertEqual(events, ["generated-c"])
        source_oracle.assert_called_once_with()
        self.assertEqual(generated_oracle.call_count, 1)

    def test_candidate_mutation_during_generated_gate_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            candidate = Path(tmpdir) / "candidate.exe"
            candidate.write_bytes(b"candidate before gate")
            resolved = str(candidate.resolve(strict=True))
            evidence_root = self.fresh_persistent_evidence_root("mutation")

            def mutate_candidate(
                path: str, root: Path, _evidence_log: list[str],
            ) -> list[str]:
                self.assertEqual(path, resolved)
                self.assertEqual(root, evidence_root)
                candidate.write_bytes(b"candidate changed during gate")
                return []

            with (
                patch.dict(
                    os.environ,
                    {
                        runner.IDENTITY_CANDIDATE_ENV: resolved,
                        runner.IDENTITY_EVIDENCE_ROOT_ENV: str(evidence_root),
                    },
                    clear=True,
                ),
                patch.object(
                    runner, "identity_checkpoint_source_errors", return_value=[]
                ),
                patch.object(
                    runner, "callable_identity_generated_c_errors",
                    side_effect=mutate_candidate,
                ) as generated_oracle,
            ):
                errors, _ = runner.identity_checkpoint_errors()

        self.assertIn(
            "candidate executable identity changed during generated-C gate",
            errors,
        )
        self.assertEqual(generated_oracle.call_count, 1)

    def test_invalid_candidate_identity_never_runs_generated_gate(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            cases = (
                ("", "is empty"),
                ("relative-candidate.exe", "must be an absolute path"),
                (str(root / "missing.exe"), "cannot resolve/hash"),
                (str(root), "is not a regular file"),
            )
            for raw, expected in cases:
                with self.subTest(candidate=raw):
                    with (
                        patch.dict(
                            os.environ,
                            {runner.IDENTITY_CANDIDATE_ENV: raw},
                            clear=True,
                        ),
                        patch.object(
                            runner, "identity_checkpoint_source_errors",
                            return_value=[],
                        ),
                        patch.object(
                            runner,
                            "callable_identity_generated_c_errors",
                        ) as generated_oracle,
                    ):
                        errors, _ = runner.identity_checkpoint_errors()

                    self.assertTrue(
                        any(expected in error for error in errors), errors)
                    generated_oracle.assert_not_called()

    def test_source_failure_stops_before_all_candidate_authorities(self) -> None:
        with (
            patch.dict(
                os.environ,
                {runner.IDENTITY_CANDIDATE_ENV: str(Path(sys.executable).resolve())},
                clear=True,
            ),
            patch.object(
                runner, "identity_checkpoint_source_errors",
                return_value=["source authority failed"],
            ) as source_oracle,
            patch.object(
                runner, "identity_checkpoint_candidate_identity",
            ) as candidate_identity,
            patch.object(
                runner, "identity_checkpoint_evidence_root",
            ) as evidence_authority,
            patch.object(
                runner, "identity_candidate_case_root",
            ) as case_root,
            patch.object(
                runner, "callable_identity_generated_c_errors",
            ) as generated_oracle,
        ):
            errors, detail = runner.identity_checkpoint_errors()

        self.assertEqual(errors, ["source authority failed"])
        self.assertEqual(
            detail, "source/mutation authority failed; candidate not evaluated")
        source_oracle.assert_called_once_with()
        candidate_identity.assert_not_called()
        evidence_authority.assert_not_called()
        case_root.assert_not_called()
        generated_oracle.assert_not_called()


if __name__ == "__main__":
    unittest.main()
