import hashlib
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch


TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

import run_tests as runner


class CompilerAnchorCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        runner._PHASE_TRACER = None

    def tearDown(self) -> None:
        runner._PHASE_TRACER = None

    @staticmethod
    def make_plan(
        root: Path,
        *,
        controlled: bool = True,
        cache_supported: bool = True,
    ) -> runner._CompilerBuildPlan:
        anchor = root / "compiler" / "dist-c" / "main.c"
        runtime = root / "vorton_runtime.cpp"
        clang = root / "tool chain" / "clang.exe"
        clangxx = root / "tool chain" / "clang++.exe"
        linker = root / "tool chain" / "lld-link.exe"
        anchor.parent.mkdir(parents=True)
        clang.parent.mkdir(parents=True)
        anchor.write_bytes(b"#include \"anchor_support.h\"\ntracked anchor\n")
        (anchor.parent / "anchor_support.h").write_bytes(b"#define VALUE 1\n")
        runtime.write_bytes(b"runtime\n")
        clang.write_bytes(b"clang tool\n")
        clangxx.write_bytes(b"clang++ tool\n")
        linker.write_bytes(b"linker tool\n")
        target = "x86_64-pc-windows-msvc" if controlled else None
        driver_flags = (
            ("--no-default-config", f"--target={target}")
            if controlled else ()
        )
        linker_pin_flags = (
            (f"-B{linker.parent.resolve()}",) if controlled else ()
        )
        environment = (
            (
                ("COMPILER_PATH", str(root / "compiler-path")),
                ("CPATH", str(root / "c headers")),
                ("CPLUS_INCLUDE_PATH", str(root / "cxx headers")),
                ("LANG", "C"),
                ("LC_ALL", "C"),
                ("LIBRARY_PATH", str(root / "libraries")),
                ("PATH", str(clang.parent.resolve())),
                ("SOURCE_DATE_EPOCH", "0"),
            )
            if controlled else ()
        )
        return runner._CompilerBuildPlan(
            anchor_source=anchor,
            runtime_source=runtime,
            clang=str(clang),
            runtime_compiler=str(clangxx),
            runtime_frontend_flags=(),
            linker=str(linker),
            exe_name="vorton.exe",
            compile_flags=("-O3", "-flto=thin"),
            test_link_flags=("-fuse-ld=lld", "-lmsvcrt"),
            compiler_link_flags=("-flto=thin",),
            controlled=controlled,
            cache_supported=cache_supported,
            target=target,
            driver_flags=driver_flags,
            linker_pin_flags=linker_pin_flags,
            environment=environment,
        )

    @staticmethod
    def replace_plan(
        plan: runner._CompilerBuildPlan,
        **changes,
    ) -> runner._CompilerBuildPlan:
        return runner._CompilerBuildPlan(**{**plan.__dict__, **changes})

    @staticmethod
    def makefile_escape(path: Path) -> str:
        return (
            str(path)
            .replace("$", "$$")
            .replace("#", r"\#")
            .replace(" ", r"\ ")
        )

    @classmethod
    def dependency_runner(
        cls,
        header: Path,
        *,
        macros: bytes = b"#define TEST_TARGET 1\n",
        capture=None,
    ):
        def run(command, **kwargs):
            depfile = Path(command[command.index("-MF") + 1])
            anchor = Path(command[-1])
            depfile.write_text(
                "vorton-cache-probe: "
                f"{cls.makefile_escape(anchor)} \\\n "
                f"{cls.makefile_escape(header)}\n",
                encoding="utf-8",
            )
            if capture is not None:
                capture.append((list(command), dict(kwargs)))
            return subprocess.CompletedProcess(command, 0, macros, b"")

        return run

    @classmethod
    def cache_inputs(
        cls,
        plan: runner._CompilerBuildPlan,
        staging_dir: Path,
        *,
        macros: bytes = b"#define TEST_TARGET 1\n",
    ):
        staging_dir.mkdir(parents=True)
        snapshot = runner._stage_anchor_snapshot(plan, staging_dir)
        header = plan.anchor_source.parent / "anchor_support.h"
        with patch.object(
            runner.subprocess,
            "run",
            side_effect=cls.dependency_runner(header, macros=macros),
        ):
            inputs = runner._compiler_cache_inputs(
                plan, snapshot, staging_dir,
            )
        return inputs, snapshot

    @staticmethod
    def simple_inputs(tag: str = "baseline"):
        return {
            "schema": runner.COMPILER_CACHE_SCHEMA,
            "version": runner.COMPILER_CACHE_VERSION,
            "tag": tag,
        }

    @classmethod
    def publish(
        cls,
        cache_root: Path,
        staging_root: Path,
        payload: bytes = b"anchor object\n",
        *,
        tag: str = "baseline",
    ):
        inputs = cls.simple_inputs(tag)
        key = runner._compiler_cache_key(inputs)
        staging_root.mkdir(parents=True, exist_ok=True)
        staged_object = staging_root / f"{tag}.o"
        staged_object.write_bytes(payload)
        cached = runner._publish_cached_anchor(
            cache_root, key, inputs, staged_object,
        )
        return inputs, key, cached

    def test_dependency_parser_preserves_windows_paths_and_escapes(self) -> None:
        dependencies = runner._parse_make_dependencies(
            "vorton-cache-probe: "
            "C:\\repo\\main.c C:/Program\\ Files/SDK/header\\#1.h "
            "C:/cash$$dir/value.h \\\n C:/next/header.h\n"
        )
        self.assertEqual(
            dependencies,
            [
                r"C:\repo\main.c",
                "C:/Program Files/SDK/header#1.h",
                "C:/cash$dir/value.h",
                "C:/next/header.h",
            ],
        )

    def test_controlled_environment_keeps_closure_inputs_but_drops_injection(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            tools = root / "tools"
            tools.mkdir()
            clang = tools / "clang.exe"
            clangxx = tools / "clang++.exe"
            linker = tools / "lld-link.exe"
            for tool in (clang, clangxx, linker):
                tool.write_bytes(b"tool\n")
            source_environment = {
                "SystemRoot": str(root / "windows"),
                "PATH": str(root / "uncontrolled-path"),
                "CPATH": str(root / "c-headers"),
                "CPLUS_INCLUDE_PATH": str(root / "cxx-headers"),
                "LIBRARY_PATH": str(root / "libraries"),
                "COMPILER_PATH": str(root / "compiler-path"),
                "CCC_OVERRIDE_OPTIONS": "+-funsafe-option",
                "CLANG_CONFIG_FILE_SYSTEM_DIR": str(root / "config"),
            }
            with patch.dict(os.environ, source_environment, clear=True):
                controlled = dict(runner._controlled_environment(
                    str(clang), str(clangxx), str(linker),
                ))

            for name in (
                "CPATH",
                "CPLUS_INCLUDE_PATH",
                "LIBRARY_PATH",
                "COMPILER_PATH",
            ):
                self.assertEqual(controlled[name], source_environment[name])
            self.assertNotIn("CCC_OVERRIDE_OPTIONS", controlled)
            self.assertNotIn("CLANG_CONFIG_FILE_SYSTEM_DIR", controlled)
            self.assertNotIn(source_environment["PATH"], controlled["PATH"])
            self.assertIn(
                str(tools.resolve()), controlled["PATH"].split(os.pathsep),
            )
            self.assertEqual(controlled["LC_ALL"], "C")
            self.assertEqual(controlled["LANG"], "C")
            self.assertEqual(controlled["SOURCE_DATE_EPOCH"], "0")

    def test_system_header_preflight_uses_actual_angle_include_surface(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "fixture.c"
            source.write_text(
                "#ifdef _WIN32\n"
                "#include <math.h>\n"
                "#else\n"
                "#include <unistd.h>\n"
                "#endif\n"
                '#include "local.h"\n'
                "#include <stdint.h>\n"
                "int ordinary_code;\n",
                encoding="utf-8",
            )
            environment = (("PATH", str(Path(temp_dir).resolve())),)
            completed = subprocess.CompletedProcess(["clang"], 0, "", "")
            with patch.object(
                runner.subprocess, "run", return_value=completed,
            ) as invoke:
                supported = runner._probe_controlled_system_headers(
                    "clang", ("--no-default-config", "--target=test"),
                    environment, source, "c", "c11",
                )

            self.assertTrue(supported)
            command = invoke.call_args.args[0]
            kwargs = invoke.call_args.kwargs
            self.assertIn("--no-default-config", command)
            self.assertIn("--target=test", command)
            self.assertIn("-E", command)
            self.assertNotIn("-c", command)
            self.assertEqual(
                kwargs["input"],
                "#ifdef _WIN32\n"
                "#include <math.h>\n"
                "#else\n"
                "#include <unistd.h>\n"
                "#endif\n"
                '#include "local.h"\n'
                "#include <stdint.h>\n"
                "\n",
            )
            self.assertEqual(kwargs["env"], dict(environment))
            self.assertIs(kwargs["stdout"], subprocess.DEVNULL)
            quote_index = command.index("-iquote")
            self.assertEqual(command[quote_index + 1], str(source.parent.resolve()))

    def test_dependency_scan_uses_exact_controlled_recipe_and_hashes_state(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "fixture with space"
            plan = self.make_plan(root)
            staging = Path(temp_dir) / "probe"
            staging.mkdir()
            snapshot = runner._stage_anchor_snapshot(plan, staging)
            header = plan.anchor_source.parent / "anchor_support.h"
            calls = []
            macros = b"#define TARGET_ABI 42\n"
            with patch.object(
                runner.subprocess,
                "run",
                side_effect=self.dependency_runner(
                    header, macros=macros, capture=calls,
                ),
            ):
                closure, state_hash = runner._scan_anchor_dependencies(
                    plan, snapshot, staging,
                )

            self.assertEqual(len(calls), 1)
            command, kwargs = calls[0]
            self.assertEqual(command[0], plan.clang)
            self.assertIn("--no-default-config", command)
            self.assertIn(f"--target={plan.target}", command)
            self.assertIn("-E", command)
            self.assertIn("-dM", command)
            self.assertIn("-MD", command)
            self.assertNotIn("-c", command)
            self.assertEqual(kwargs["env"], dict(plan.environment))
            self.assertEqual(
                state_hash, hashlib.sha256(macros).hexdigest(),
            )
            self.assertEqual(
                closure,
                (runner._stable_file_identity(header.resolve()),),
            )
            self.assertEqual(list(staging.glob("anchor-*.d")), [])

    def test_cache_key_is_stable_across_fresh_snapshot_directories(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            plan = self.make_plan(root / "fixture with space")
            first, _ = self.cache_inputs(plan, root / "staging one")
            second, _ = self.cache_inputs(plan, root / "staging two")

            self.assertEqual(first, second)
            self.assertEqual(
                runner._compiler_cache_key(first),
                runner._compiler_cache_key(second),
            )
            self.assertEqual(first["anchor"]["path"], "$tracked_c_anchor")
            recipes = first["recipes"]
            self.assertEqual(
                set(recipes),
                {
                    "anchor_dependency_scan",
                    "anchor_compile",
                    "runtime_compile",
                    "link",
                },
            )
            for recipe in recipes.values():
                self.assertIn("--no-default-config", recipe)
                self.assertIn(f"--target={plan.target}", recipe)
            self.assertIn(plan.linker_pin_flags[0], recipes["link"])
            self.assertEqual(first["environment"], dict(plan.environment))

    def test_cache_key_invalidates_for_source_header_macro_and_recipe(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            plan = self.make_plan(root / "fixture")
            baseline, _ = self.cache_inputs(plan, root / "baseline")
            baseline_key = runner._compiler_cache_key(baseline)

            plan.anchor_source.write_bytes(b"changed anchor\n")
            changed_anchor, _ = self.cache_inputs(plan, root / "anchor change")
            self.assertNotEqual(
                runner._compiler_cache_key(changed_anchor), baseline_key,
            )
            plan.anchor_source.write_bytes(
                b"#include \"anchor_support.h\"\ntracked anchor\n"
            )

            header = plan.anchor_source.parent / "anchor_support.h"
            header.write_bytes(b"#define VALUE 2\n")
            changed_header, _ = self.cache_inputs(plan, root / "header change")
            self.assertNotEqual(
                runner._compiler_cache_key(changed_header), baseline_key,
            )
            header.write_bytes(b"#define VALUE 1\n")

            changed_macros, _ = self.cache_inputs(
                plan, root / "macro change",
                macros=b"#define TEST_TARGET 2\n",
            )
            self.assertNotEqual(
                runner._compiler_cache_key(changed_macros), baseline_key,
            )

            changed_flags = self.replace_plan(
                plan, compile_flags=("-O2", "-flto=thin"),
            )
            changed_recipe, _ = self.cache_inputs(
                changed_flags, root / "recipe change",
            )
            self.assertNotEqual(
                runner._compiler_cache_key(changed_recipe), baseline_key,
            )

    def test_cache_key_invalidates_for_environment_target_and_tool_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            plan = self.make_plan(root / "fixture")
            baseline, _ = self.cache_inputs(plan, root / "baseline")
            baseline_key = runner._compiler_cache_key(baseline)

            for name in (
                "CPATH",
                "CPLUS_INCLUDE_PATH",
                "LIBRARY_PATH",
                "COMPILER_PATH",
            ):
                environment = dict(plan.environment)
                environment[name] += "-changed"
                changed_plan = self.replace_plan(
                    plan,
                    environment=tuple(sorted(environment.items())),
                )
                changed, _ = self.cache_inputs(
                    changed_plan, root / f"environment {name}",
                )
                self.assertNotEqual(
                    runner._compiler_cache_key(changed), baseline_key, name,
                )

            other_target = "aarch64-pc-windows-msvc"
            target_plan = self.replace_plan(
                plan,
                target=other_target,
                driver_flags=(
                    "--no-default-config", f"--target={other_target}",
                ),
            )
            target_inputs, _ = self.cache_inputs(
                target_plan, root / "target change",
            )
            self.assertNotEqual(
                runner._compiler_cache_key(target_inputs), baseline_key,
            )

            Path(plan.clang).write_bytes(b"changed clang tool\n")
            tool_inputs, _ = self.cache_inputs(plan, root / "tool change")
            self.assertNotEqual(
                runner._compiler_cache_key(tool_inputs), baseline_key,
            )

    def test_dependency_probe_failure_is_loud_and_leaves_no_depfile(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            plan = self.make_plan(root / "fixture")
            staging = root / "staging"
            staging.mkdir()
            snapshot = runner._stage_anchor_snapshot(plan, staging)
            failure = subprocess.CalledProcessError(
                17, [plan.clang, "-E"], stderr=b"probe failed",
            )
            with patch.object(
                runner.subprocess, "run", side_effect=failure,
            ):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    runner._scan_anchor_dependencies(plan, snapshot, staging)

            self.assertIs(raised.exception, failure)
            self.assertEqual(list(staging.glob("anchor-*.d")), [])
            self.assertFalse((staging / "main.o").exists())

    def test_dependency_probe_rejects_an_unresolved_closure_member(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            plan = self.make_plan(root / "fixture")
            staging = root / "staging"
            staging.mkdir()
            snapshot = runner._stage_anchor_snapshot(plan, staging)
            missing = root / "missing header.h"
            with patch.object(
                runner.subprocess,
                "run",
                side_effect=self.dependency_runner(missing),
            ):
                with self.assertRaisesRegex(
                    runner.CompilerPreparationError,
                    "dependency cannot be resolved",
                ):
                    runner._scan_anchor_dependencies(
                        plan, snapshot, staging,
                    )

    def test_controlled_commands_share_driver_environment_and_linker_pin(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            plan = self.make_plan(root / "fixture")
            build_dir = root / "build"
            build_dir.mkdir()
            snapshot = runner._stage_anchor_snapshot(plan, build_dir)
            calls = []

            def successful_stage(stage, command, **kwargs):
                calls.append((stage, list(command), dict(kwargs)))
                output = Path(command[command.index("-o") + 1])
                output.write_bytes(stage.encode("utf-8"))
                return subprocess.CompletedProcess(command, 0, b"", b"")

            with (
                patch.object(runner, "THINLTO_CACHE", root / "thinlto"),
                patch.object(
                    runner, "_run_subprocess", side_effect=successful_stage,
                ),
            ):
                runner._compile_anchor(plan, build_dir, snapshot)
                runner._compile_runtime_and_link(plan, build_dir, snapshot)

            self.assertEqual(
                [stage for stage, _command, _kwargs in calls],
                [
                    "compiler_anchor_compile",
                    "compiler_runtime_compile",
                    "compiler_link",
                ],
            )
            for _stage, command, kwargs in calls:
                self.assertIn("--no-default-config", command)
                self.assertIn(f"--target={plan.target}", command)
                self.assertEqual(kwargs["env"], dict(plan.environment))
            anchor_command = calls[0][1]
            prefix_flag = next(
                flag for flag in anchor_command
                if flag.startswith("-ffile-prefix-map=")
            )
            self.assertEqual(
                prefix_flag,
                f"-ffile-prefix-map={snapshot.parent}="
                f"{plan.anchor_source.parent.resolve()}",
            )
            self.assertIn(plan.linker_pin_flags[0], calls[2][1])

    def test_partial_stale_corrupt_and_wrong_mode_entries_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            inputs = self.simple_inputs()
            key = runner._compiler_cache_key(inputs)
            receipt_path, _ = runner._cache_paths(cache_root, key)
            receipt_path.parent.mkdir(parents=True)

            receipt_path.write_text("{", encoding="utf-8")
            self.assertIsNone(
                runner._validated_cached_anchor(cache_root, key, inputs)
            )
            receipt_path.unlink()

            _inputs, _key, cached = self.publish(
                cache_root, root / "staging",
            )
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["inputs"] = self.simple_inputs("stale")
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            self.assertIsNone(
                runner._validated_cached_anchor(cache_root, key, inputs)
            )

            receipt_path.write_text(
                json.dumps({**receipt, "inputs": inputs}), encoding="utf-8",
            )
            cached.path.write_bytes(b"corrupt after receipt\n")
            self.assertIsNone(
                runner._validated_cached_anchor(cache_root, key, inputs)
            )

            cached.path.write_bytes(b"anchor object\n")
            receipt["inputs"] = inputs
            receipt["artifact_mode"] = receipt["artifact_mode"] ^ 0o100
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            self.assertIsNone(
                runner._validated_cached_anchor(cache_root, key, inputs)
            )

    def test_invalid_receipt_fails_loud_on_lookup(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            inputs = self.simple_inputs()
            key = runner._compiler_cache_key(inputs)
            receipt_path, _ = runner._cache_paths(cache_root, key)
            receipt_path.parent.mkdir(parents=True)
            receipt_path.write_text("{", encoding="utf-8")

            with self.assertRaisesRegex(
                runner.CompilerPreparationError,
                "cache entry failed validation",
            ):
                runner._lookup_cached_anchor(
                    cache_root, key, inputs, root / "fresh" / "main.o",
                )

    def test_hit_copies_verified_object_into_each_fresh_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            inputs, key, _cached = self.publish(
                cache_root, root / "staging",
            )
            first = root / "run one" / "main.o"
            second = root / "run two" / "main.o"
            first.parent.mkdir()
            second.parent.mkdir()

            self.assertTrue(runner._lookup_cached_anchor(
                cache_root, key, inputs, first,
            ))
            self.assertTrue(runner._lookup_cached_anchor(
                cache_root, key, inputs, second,
            ))
            self.assertEqual(first.read_bytes(), b"anchor object\n")
            self.assertEqual(second.read_bytes(), b"anchor object\n")
            self.assertNotEqual(first.parent, second.parent)
            self.assertNotEqual(first.parent, cache_root)

    def test_fresh_copy_revalidates_hash_size_and_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "source.o"
            destination = root / "destination.o"
            source.write_bytes(b"changed object\n")
            expected = runner._CachedAnchor(
                path=source,
                sha256=hashlib.sha256(b"expected object\n").hexdigest(),
                size=len(b"expected object\n"),
                mode=runner._artifact_mode(source),
            )
            with self.assertRaisesRegex(
                runner.CompilerPreparationError,
                "copy failed receipt validation",
            ):
                runner._copy_cached_anchor(expected, destination)

    def test_same_payload_concurrent_publish_shares_immutable_winner(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            inputs = self.simple_inputs()
            key = runner._compiler_cache_key(inputs)
            objects = [root / "first.o", root / "second.o"]
            for path in objects:
                path.write_bytes(b"identical object\n")
            barrier = threading.Barrier(2)

            def publish(path):
                barrier.wait(timeout=5)
                return runner._publish_cached_anchor(
                    cache_root, key, inputs, path,
                )

            with ThreadPoolExecutor(max_workers=2) as pool:
                winners = list(pool.map(publish, objects))

            self.assertTrue(runner._same_cached_anchor(
                winners[0], winners[1],
            ))
            self.assertIsNotNone(
                runner._validated_cached_anchor(cache_root, key, inputs)
            )
            self.assertEqual(
                list((cache_root / "receipts").glob("*.json")).__len__(),
                1,
            )
            self.assertEqual(
                list((cache_root / "conflicts").glob("*/*.json")), [],
            )

    def test_divergent_concurrent_publish_persists_conflict_without_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            inputs = self.simple_inputs()
            key = runner._compiler_cache_key(inputs)
            objects = [root / "first.o", root / "second.o"]
            objects[0].write_bytes(b"first divergent object\n")
            objects[1].write_bytes(b"second divergent object\n")
            barrier = threading.Barrier(2)

            def publish(path):
                barrier.wait(timeout=5)
                try:
                    return runner._publish_cached_anchor(
                        cache_root, key, inputs, path,
                    )
                except BaseException as exc:
                    return exc

            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(publish, objects))

            winners = [
                result for result in results
                if isinstance(result, runner._CachedAnchor)
            ]
            failures = [
                result for result in results
                if isinstance(result, runner.CompilerPreparationError)
            ]
            self.assertEqual(len(winners), 1)
            self.assertEqual(len(failures), 1)
            self.assertIn("divergent anchor objects", str(failures[0]))
            receipt_path, _ = runner._cache_paths(cache_root, key)
            self.assertFalse(receipt_path.exists())
            conflicts = list(
                (cache_root / "conflicts" / key).glob("*.json")
            )
            self.assertEqual(len(conflicts), 1)
            evidence = json.loads(conflicts[0].read_text(encoding="utf-8"))
            self.assertEqual(evidence["winner"]["sha256"], winners[0].sha256)
            self.assertNotEqual(
                evidence["candidate"]["sha256"], winners[0].sha256,
            )
            poison = runner._cache_poison_path(cache_root, key)
            self.assertTrue(poison.is_file())
            poison_before = poison.read_bytes()
            poison_record = json.loads(poison.read_text(encoding="utf-8"))
            self.assertEqual(poison_record["key"], key)
            self.assertEqual(
                poison_record["artifact_sha256"], winners[0].sha256,
            )
            destination = root / "future-hit.o"
            with self.assertRaisesRegex(
                runner.CompilerPreparationError, "prior divergent build",
            ):
                runner._lookup_cached_anchor(
                    cache_root, key, inputs, destination,
                )
            self.assertFalse(destination.exists())
            with self.assertRaisesRegex(
                runner.CompilerPreparationError, "prior divergent build",
            ):
                runner._publish_cached_anchor(
                    cache_root, key, inputs, objects[0],
                )
            self.assertEqual(poison.read_bytes(), poison_before)
            self.assertFalse(receipt_path.exists())

    def test_conflict_evidence_failure_cannot_forget_durable_poison(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            inputs, key, winner = self.publish(
                cache_root, root / "winner", b"winner object\n",
            )
            divergent = root / "divergent.o"
            divergent.write_bytes(b"divergent object\n")

            with patch.object(
                runner, "_record_cache_conflict_locked",
                side_effect=OSError("conflict evidence fsync failure"),
            ):
                with self.assertRaisesRegex(
                    OSError, "conflict evidence fsync failure",
                ):
                    runner._publish_cached_anchor(
                        cache_root, key, inputs, divergent,
                    )

            receipt_path, _ = runner._cache_paths(cache_root, key)
            poison = runner._cache_poison_path(cache_root, key)
            self.assertFalse(receipt_path.exists())
            self.assertTrue(poison.is_file())
            poisoned_receipt = json.loads(poison.read_text(encoding="utf-8"))
            self.assertEqual(
                poisoned_receipt["artifact_sha256"], winner.sha256,
            )
            with self.assertRaisesRegex(
                runner.CompilerPreparationError, "prior divergent build",
            ):
                runner._lookup_cached_anchor(
                    cache_root, key, inputs, root / "future.o",
                )
            with self.assertRaisesRegex(
                runner.CompilerPreparationError, "prior divergent build",
            ):
                runner._publish_cached_anchor(
                    cache_root, key, inputs, divergent,
                )

    def test_poison_rename_failure_uses_independent_durable_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            inputs, key, _ = self.publish(
                cache_root, root / "winner", b"winner object\n",
            )
            divergent = root / "divergent.o"
            divergent.write_bytes(b"divergent object\n")

            with patch.object(
                runner.os, "replace", side_effect=OSError("rename failure"),
            ):
                with self.assertRaisesRegex(
                    runner.CompilerPreparationError,
                    "divergent anchor objects",
                ):
                    runner._publish_cached_anchor(
                        cache_root, key, inputs, divergent,
                    )

            receipt_path, _ = runner._cache_paths(cache_root, key)
            poison = runner._cache_poison_path(cache_root, key)
            self.assertTrue(receipt_path.is_file())
            self.assertTrue(poison.is_file())
            marker = json.loads(poison.read_text(encoding="utf-8"))
            self.assertTrue(runner._is_cache_poison_record(marker, key))
            with self.assertRaisesRegex(
                runner.CompilerPreparationError, "prior divergent build",
            ):
                runner._lookup_cached_anchor(
                    cache_root, key, inputs, root / "future.o",
                )
            with self.assertRaisesRegex(
                runner.CompilerPreparationError, "prior divergent build",
            ):
                runner._publish_cached_anchor(
                    cache_root, key, inputs, divergent,
                )
            runner._cleanup_compiler_cache_locked(cache_root)
            self.assertFalse(receipt_path.exists())
            self.assertTrue(poison.exists())

    def test_all_external_poison_publication_failures_invalidate_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            inputs, key, _ = self.publish(
                cache_root, root / "winner", b"winner object\n",
            )
            divergent = root / "divergent.o"
            divergent.write_bytes(b"divergent object\n")

            with (
                patch.object(
                    runner.os, "replace", side_effect=OSError("rename failure"),
                ),
                patch.object(
                    runner, "_create_json_once",
                    side_effect=OSError("create-once failure"),
                ),
            ):
                with self.assertRaisesRegex(OSError, "create-once failure"):
                    runner._publish_cached_anchor(
                        cache_root, key, inputs, divergent,
                    )

            receipt_path, _ = runner._cache_paths(cache_root, key)
            marker = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertTrue(runner._is_cache_poison_record(marker, key))
            self.assertFalse(runner._cache_poison_path(cache_root, key).exists())
            with self.assertRaisesRegex(
                runner.CompilerPreparationError, "prior divergent build",
            ):
                runner._lookup_cached_anchor(
                    cache_root, key, inputs, root / "future.o",
                )
            with self.assertRaisesRegex(
                runner.CompilerPreparationError, "prior divergent build",
            ):
                runner._publish_cached_anchor(
                    cache_root, key, inputs, divergent,
                )
            runner._cleanup_compiler_cache_locked(cache_root)
            self.assertTrue(receipt_path.exists())

    def test_mode_only_divergence_survives_double_fault_and_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            payload = b"identical object bytes\n"
            inputs, key, winner = self.publish(
                cache_root, root / "winner", payload,
            )
            divergent = root / "divergent.o"
            divergent.write_bytes(payload)
            os.chmod(divergent, winner.mode ^ stat.S_IWUSR)
            candidate = runner._candidate_anchor(divergent)
            self.assertEqual(candidate.sha256, winner.sha256)
            self.assertEqual(candidate.size, winner.size)
            self.assertNotEqual(candidate.mode, winner.mode)
            self.assertFalse(runner._same_cached_anchor(winner, candidate))

            with (
                patch.object(
                    runner.os, "replace", side_effect=OSError("rename failure"),
                ),
                patch.object(
                    runner, "_create_json_once",
                    side_effect=OSError("create-once failure"),
                ),
            ):
                with self.assertRaisesRegex(OSError, "create-once failure"):
                    runner._publish_cached_anchor(
                        cache_root, key, inputs, divergent,
                    )

            receipt_path, _ = runner._cache_paths(cache_root, key)
            marker = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertTrue(runner._is_cache_poison_record(marker, key))
            self.assertEqual(
                marker["winner"]["sha256"], marker["candidate"]["sha256"],
            )
            self.assertNotEqual(
                marker["winner"]["mode"], marker["candidate"]["mode"],
            )
            runner._cleanup_compiler_cache_locked(cache_root)
            self.assertTrue(receipt_path.exists())
            with self.assertRaisesRegex(
                runner.CompilerPreparationError, "prior divergent build",
            ):
                runner._lookup_cached_anchor(
                    cache_root, key, inputs, root / "future.o",
                )
            with self.assertRaisesRegex(
                runner.CompilerPreparationError, "prior divergent build",
            ):
                runner._publish_cached_anchor(
                    cache_root, key, inputs, divergent,
                )

    def test_hardlink_publication_failure_is_loud_and_never_creates_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            inputs = self.simple_inputs()
            key = runner._compiler_cache_key(inputs)
            staged = root / "main.o"
            staged.write_bytes(b"object\n")

            with patch.object(
                runner.os, "link", side_effect=OSError("no hard links"),
            ):
                with self.assertRaisesRegex(
                    runner.CompilerPreparationError,
                    "requires atomic hard-link publication",
                ):
                    runner._publish_cached_anchor(
                        cache_root, key, inputs, staged,
                    )

            receipt, artifacts = runner._cache_paths(cache_root, key)
            self.assertFalse(receipt.exists())
            self.assertEqual(list(artifacts.glob("*.o")), [])

    def test_cleanup_bounds_entries_bytes_conflicts_and_orphan_staging(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            receipts = cache_root / "receipts"
            artifacts = cache_root / "artifacts"
            access = cache_root / "access"
            conflicts = cache_root / "conflicts" / "key"
            now = time.time()
            published = []
            for tag, payload, used in (
                ("old", b"old", now - 20),
                ("new", b"newer", now - 10),
            ):
                _, key, cached = self.publish(
                    cache_root, root / f"staging-{tag}", payload, tag=tag,
                )
                published.append((tag, key, cached))
                marker = access / key
                os.utime(marker, (used, used))

            conflicts.mkdir(parents=True)
            (artifacts / "orphan.o").write_bytes(b"orphan")
            old_staging = cache_root / ".staging-old"
            new_staging = cache_root / ".staging-new"
            old_staging.mkdir()
            new_staging.mkdir()
            old_time = now - runner.COMPILER_CACHE_STALE_SECONDS - 1
            os.utime(old_staging, (old_time, old_time))
            for index in range(3):
                conflict = conflicts / f"{index}.json"
                conflict.write_text("{}", encoding="utf-8")
                os.utime(conflict, (now + index, now + index))

            with (
                patch.object(runner, "COMPILER_CACHE_MAX_ENTRIES", 10),
                patch.object(runner, "COMPILER_CACHE_MAX_BYTES", 5),
                patch.object(runner, "COMPILER_CACHE_MAX_CONFLICTS", 1),
            ):
                runner._cleanup_compiler_cache_locked(
                    cache_root, now=now,
                )

            old_tag, old_key, old_cached = published[0]
            new_tag, new_key, new_cached = published[1]
            self.assertFalse((receipts / f"{old_key}.json").exists())
            self.assertTrue((receipts / f"{new_key}.json").exists())
            self.assertFalse(old_cached.path.exists())
            self.assertTrue(new_cached.path.exists())
            self.assertFalse((artifacts / "orphan.o").exists())
            self.assertFalse((access / old_key).exists())
            self.assertTrue((access / new_key).exists())
            self.assertFalse(old_staging.exists())
            self.assertTrue(new_staging.exists())
            self.assertEqual(len(list(conflicts.glob("*.json"))), 1)
            self.assertTrue((conflicts / "2.json").exists())

    def test_cleanup_uses_actual_artifact_size_and_removes_malformed_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            _, key, cached = self.publish(
                cache_root, root / "staging", b"x" * 100,
            )
            receipt_path, _ = runner._cache_paths(cache_root, key)
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["artifact_size"] = 0
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")

            with patch.object(runner, "COMPILER_CACHE_MAX_BYTES", 1):
                runner._cleanup_compiler_cache_locked(cache_root)

            self.assertFalse(receipt_path.exists())
            self.assertFalse(cached.path.exists())
            self.assertFalse((cache_root / "access" / key).exists())

    def test_poison_tombstone_participates_in_entry_lru_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            poisoned_inputs, poisoned_key, _ = self.publish(
                cache_root, root / "poison-winner", b"winner\n", tag="poison",
            )
            divergent = root / "divergent.o"
            divergent.write_bytes(b"divergent\n")
            with self.assertRaisesRegex(
                runner.CompilerPreparationError, "divergent anchor objects",
            ):
                runner._publish_cached_anchor(
                    cache_root, poisoned_key, poisoned_inputs, divergent,
                )
            _, new_key, new_cached = self.publish(
                cache_root, root / "new", b"new\n", tag="new",
            )
            now = time.time()
            old_access = cache_root / "access" / poisoned_key
            new_access = cache_root / "access" / new_key
            os.utime(old_access, (now - 20, now - 20))
            os.utime(new_access, (now - 10, now - 10))

            with patch.object(runner, "COMPILER_CACHE_MAX_ENTRIES", 1):
                runner._cleanup_compiler_cache_locked(cache_root, now=now)

            self.assertFalse(
                runner._cache_poison_path(cache_root, poisoned_key).exists()
            )
            self.assertFalse(old_access.exists())
            new_receipt, _ = runner._cache_paths(cache_root, new_key)
            self.assertTrue(new_receipt.exists())
            self.assertTrue(new_cached.path.exists())

    def test_cache_hit_phase_order_and_exact_runner_scoped_fields(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            trace_path = root / "trace.jsonl"
            plan = self.make_plan(root / "fixture")

            def cache_hit(_root, _key, _inputs, destination):
                destination.write_bytes(b"cached anchor\n")
                return True

            def successful_tool(command, **_kwargs):
                if "-MF" in command:
                    depfile = Path(command[command.index("-MF") + 1])
                    anchor = Path(command[-1])
                    header = plan.anchor_source.parent / "anchor_support.h"
                    depfile.write_text(
                        "vorton-cache-probe: "
                        f"{self.makefile_escape(anchor)} "
                        f"{self.makefile_escape(header)}\n",
                        encoding="utf-8",
                    )
                    return subprocess.CompletedProcess(
                        command, 0, b"#define TEST_TARGET 1\n", b"",
                    )
                output = Path(command[command.index("-o") + 1])
                output.write_bytes(b"stage output\n")
                return subprocess.CompletedProcess(command, 0, b"", b"")

            clock = iter(range(0, 1000, 10))
            with (
                patch.object(runner, "COMPILER_ARTIFACT_CACHE", cache_root),
                patch.dict(
                    os.environ, {runner.COMPILER_CACHE_ENV: "1"}, clear=False,
                ),
                patch.object(
                    runner, "_lookup_cached_anchor", side_effect=cache_hit,
                ),
                patch.object(
                    runner.subprocess, "run", side_effect=successful_tool,
                ),
                patch.object(
                    runner.time, "perf_counter_ns", side_effect=clock,
                ),
            ):
                tracer = runner.PhaseTimingTrace(str(trace_path))
                runner._PHASE_TRACER = tracer
                executable = Path(runner._prepare_compiler(plan))
                tracer.finish(complete=True, outcome="success", exit_code=0)
                tracer.close()

            self.assertTrue(executable.is_file())
            records = [
                json.loads(line)
                for line in trace_path.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(
                [record["stage"] for record in records],
                [
                    "compiler_anchor_dependency_scan",
                    "compiler_anchor_prepare",
                    "compiler_anchor_dependency_scan",
                    "compiler_runtime_compile",
                    "compiler_link",
                    "orchestration_residual",
                    "runner_total",
                ],
            )
            cached = records[1]
            self.assertEqual(set(cached), runner.PHASE_TIMING_FIELDS)
            self.assertIsNone(cached["suite"])
            self.assertEqual(cached["case"], "runner")
            self.assertFalse(cached["executed"])
            self.assertTrue(cached["complete"])
            self.assertEqual(cached["outcome"], "cached")
            self.assertIsNone(cached["exit_code"])
            self.assertIsNone(cached["command_category"])
            for child in (records[0], records[2], records[3], records[4]):
                self.assertTrue(child["executed"])
                self.assertTrue(child["complete"])
                self.assertEqual(child["outcome"], "success")
                self.assertEqual(child["exit_code"], 0)
                self.assertEqual(child["command_category"], "clang")
            self.assertEqual(
                sum(record["duration_ns"] for record in records[:-1]),
                records[-1]["duration_ns"],
            )

    def test_cache_miss_records_dependency_scans_and_three_build_stages(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            trace_path = root / "trace.jsonl"
            plan = self.make_plan(root / "fixture")

            def successful_tool(command, **_kwargs):
                if "-MF" in command:
                    depfile = Path(command[command.index("-MF") + 1])
                    anchor = Path(command[-1])
                    header = plan.anchor_source.parent / "anchor_support.h"
                    depfile.write_text(
                        "vorton-cache-probe: "
                        f"{self.makefile_escape(anchor)} "
                        f"{self.makefile_escape(header)}\n",
                        encoding="utf-8",
                    )
                    return subprocess.CompletedProcess(
                        command, 0, b"#define TEST_TARGET 1\n", b"",
                    )
                output = Path(command[command.index("-o") + 1])
                output.write_bytes(
                    b"linked compiler\n"
                    if output.suffix == ".exe" else b"object\n"
                )
                return subprocess.CompletedProcess(command, 0, b"", b"")

            clock = iter(range(0, 1000, 10))
            with (
                patch.object(runner, "COMPILER_ARTIFACT_CACHE", cache_root),
                patch.object(runner, "THINLTO_CACHE", root / "thinlto"),
                patch.dict(
                    os.environ, {runner.COMPILER_CACHE_ENV: "1"}, clear=False,
                ),
                patch.object(
                    runner, "_lookup_cached_anchor", return_value=False,
                ),
                patch.object(
                    runner.subprocess, "run", side_effect=successful_tool,
                ) as child_run,
                patch.object(
                    runner.time, "perf_counter_ns", side_effect=clock,
                ),
            ):
                tracer = runner.PhaseTimingTrace(str(trace_path))
                runner._PHASE_TRACER = tracer
                executable = Path(runner._prepare_compiler(plan))
                tracer.finish(complete=True, outcome="success", exit_code=0)
                tracer.close()

            self.assertTrue(executable.is_file())
            self.assertEqual(child_run.call_count, 5)
            records = [
                json.loads(line)
                for line in trace_path.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(
                [record["stage"] for record in records],
                [
                    "compiler_anchor_dependency_scan",
                    "compiler_anchor_compile",
                    "compiler_anchor_dependency_scan",
                    "compiler_runtime_compile",
                    "compiler_link",
                    "orchestration_residual",
                    "runner_total",
                ],
            )
            for child in records[:5]:
                self.assertTrue(child["executed"])
                self.assertTrue(child["complete"])
                self.assertEqual(child["outcome"], "success")
                self.assertEqual(child["exit_code"], 0)
                self.assertEqual(child["command_category"], "clang")

    def test_changed_post_compile_closure_is_not_published_or_linked(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            plan = self.make_plan(root / "fixture")
            inputs = self.simple_inputs()
            changed_inputs = self.simple_inputs("changed-after-compile")

            def successful_anchor(command, **_kwargs):
                output = Path(command[command.index("-o") + 1])
                output.write_bytes(b"object\n")
                return subprocess.CompletedProcess(command, 0, b"", b"")

            with (
                patch.object(runner, "COMPILER_ARTIFACT_CACHE", cache_root),
                patch.object(runner, "THINLTO_CACHE", root / "thinlto"),
                patch.dict(
                    os.environ, {runner.COMPILER_CACHE_ENV: "1"}, clear=False,
                ),
                patch.object(
                    runner, "_compiler_cache_inputs",
                    side_effect=[inputs, changed_inputs],
                ),
                patch.object(
                    runner, "_lookup_cached_anchor", return_value=False,
                ),
                patch.object(
                    runner.subprocess, "run", side_effect=successful_anchor,
                ) as child_run,
                patch.object(runner, "_publish_cached_anchor") as publish,
            ):
                with self.assertRaisesRegex(
                    runner.CompilerPreparationError,
                    "inputs changed during construction",
                ):
                    runner._prepare_compiler(plan)

            self.assertEqual(child_run.call_count, 1)
            publish.assert_not_called()
            self.assertEqual(list(cache_root.glob(".staging-*")), [])

    def test_build_failure_is_not_retried_or_published(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            plan = self.make_plan(root / "fixture")
            inputs = self.simple_inputs()
            failure = subprocess.CalledProcessError(
                23, [plan.clang, "-c"], stderr=b"original compiler failure",
            )
            with (
                patch.object(runner, "COMPILER_ARTIFACT_CACHE", cache_root),
                patch.object(runner, "THINLTO_CACHE", root / "thinlto"),
                patch.dict(
                    os.environ, {runner.COMPILER_CACHE_ENV: "1"}, clear=False,
                ),
                patch.object(
                    runner, "_compiler_cache_inputs", return_value=inputs,
                ),
                patch.object(
                    runner, "_lookup_cached_anchor", return_value=False,
                ),
                patch.object(
                    runner.subprocess, "run", side_effect=failure,
                ) as child_run,
                patch.object(runner, "_publish_cached_anchor") as publish,
            ):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    runner._prepare_compiler(plan)

            self.assertIs(raised.exception, failure)
            self.assertEqual(child_run.call_count, 1)
            publish.assert_not_called()
            self.assertFalse((cache_root / "receipts").exists())
            self.assertEqual(list(cache_root.glob(".staging-*")), [])

    def test_disable_switch_bypasses_only_cache_with_same_controlled_recipe(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cache_root = root / "cache"
            plan = self.make_plan(root / "fixture")
            commands = []

            def successful_tool(command, **kwargs):
                commands.append((list(command), dict(kwargs)))
                output = Path(command[command.index("-o") + 1])
                output.write_bytes(b"uncached stage\n")
                return subprocess.CompletedProcess(command, 0, b"", b"")

            with (
                patch.object(runner, "COMPILER_ARTIFACT_CACHE", cache_root),
                patch.object(runner, "THINLTO_CACHE", root / "thinlto"),
                patch.dict(
                    os.environ, {runner.COMPILER_CACHE_ENV: "0"}, clear=False,
                ),
                patch.object(
                    runner, "_compiler_cache_inputs",
                ) as cache_inputs,
                patch.object(
                    runner, "_lookup_cached_anchor",
                ) as lookup,
                patch.object(
                    runner.subprocess, "run", side_effect=successful_tool,
                ),
            ):
                executable = Path(runner._prepare_compiler(plan))

            self.assertTrue(executable.is_file())
            cache_inputs.assert_not_called()
            lookup.assert_not_called()
            self.assertEqual(len(commands), 3)
            for command, kwargs in commands:
                self.assertIn("--no-default-config", command)
                self.assertIn(f"--target={plan.target}", command)
                self.assertEqual(kwargs["env"], dict(plan.environment))
            self.assertIn(plan.linker_pin_flags[0], commands[-1][0])
            self.assertNotEqual(executable.parent, cache_root)

    def test_unsupported_platform_path_uses_original_uncached_full_build(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            plan = self.make_plan(
                root / "fixture", controlled=False, cache_supported=False,
            )
            calls = []

            def compile_anchor(_plan, build_dir, source):
                calls.append(("anchor", source))
                output = build_dir / "main.o"
                output.write_bytes(b"object\n")
                return output

            def runtime_and_link(_plan, build_dir, source):
                calls.append(("runtime-link", source))
                output = build_dir / plan.exe_name
                output.write_bytes(b"compiler\n")
                return output

            with (
                patch.object(
                    runner, "_compile_anchor", side_effect=compile_anchor,
                ),
                patch.object(
                    runner, "_compile_runtime_and_link",
                    side_effect=runtime_and_link,
                ),
                patch.object(runner, "_stage_anchor_snapshot") as snapshot,
                patch.object(runner, "_compiler_cache_inputs") as inputs,
            ):
                executable = Path(runner._prepare_compiler(plan))

            self.assertTrue(executable.is_file())
            self.assertEqual(
                calls,
                [
                    ("anchor", plan.anchor_source),
                    ("runtime-link", plan.anchor_source),
                ],
            )
            snapshot.assert_not_called()
            inputs.assert_not_called()

    def test_incompatible_controlled_driver_falls_back_to_original_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self.make_plan(Path(temp_dir) / "fixture")
            with (
                patch.object(runner.sys, "platform", "win32"),
                patch.object(runner, "DIST_C_MAIN", fixture.anchor_source),
                patch.object(runner, "RUNTIME_CPP", fixture.runtime_source),
                patch.object(
                    runner, "find_clang", return_value=fixture.clang,
                ),
                patch.object(
                    runner.shutil, "which",
                    return_value=fixture.runtime_compiler,
                ),
                patch.object(
                    runner, "_resolved_executable",
                    side_effect=lambda executable: executable,
                ),
                patch.object(
                    runner, "_find_lld_linker", return_value=fixture.linker,
                ),
                patch.object(
                    runner, "_controlled_environment",
                    return_value=fixture.environment,
                ),
                patch.object(
                    runner, "_probe_controlled_target",
                    side_effect=[fixture.target, None],
                ),
            ):
                plan = runner._compiler_build_plan()

            self.assertIsNotNone(plan)
            self.assertFalse(plan.controlled)
            self.assertFalse(plan.cache_supported)
            self.assertEqual(plan.driver_flags, ())
            self.assertEqual(plan.linker_pin_flags, ())
            self.assertIsNone(plan.target)
            self.assertIsNone(runner._plan_environment(plan))

    def test_matching_targets_without_system_headers_fall_back_to_original_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self.make_plan(Path(temp_dir) / "fixture")
            with (
                patch.object(runner.sys, "platform", "win32"),
                patch.object(runner, "DIST_C_MAIN", fixture.anchor_source),
                patch.object(runner, "RUNTIME_CPP", fixture.runtime_source),
                patch.object(runner, "find_clang", return_value=fixture.clang),
                patch.object(runner.shutil, "which", return_value=fixture.runtime_compiler),
                patch.object(
                    runner, "_resolved_executable",
                    side_effect=lambda executable: executable,
                ),
                patch.object(runner, "_find_lld_linker", return_value=fixture.linker),
                patch.object(
                    runner, "_controlled_environment",
                    return_value=fixture.environment,
                ),
                patch.object(
                    runner, "_probe_controlled_target",
                    side_effect=[fixture.target, fixture.target],
                ),
                patch.object(
                    runner, "_probe_controlled_system_headers",
                    side_effect=[False, True],
                ) as header_probe,
            ):
                plan = runner._compiler_build_plan()

            self.assertIsNotNone(plan)
            self.assertFalse(plan.controlled)
            self.assertFalse(plan.cache_supported)
            self.assertEqual(plan.driver_flags, ())
            self.assertEqual(plan.linker_pin_flags, ())
            self.assertIsNone(plan.target)
            self.assertIsNone(runner._plan_environment(plan))
            self.assertEqual(header_probe.call_count, 2)

    def test_matching_targets_and_system_headers_enable_controlled_cache(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self.make_plan(Path(temp_dir) / "fixture")
            with (
                patch.object(runner.sys, "platform", "win32"),
                patch.object(runner, "DIST_C_MAIN", fixture.anchor_source),
                patch.object(runner, "RUNTIME_CPP", fixture.runtime_source),
                patch.object(runner, "find_clang", return_value=fixture.clang),
                patch.object(runner.shutil, "which", return_value=fixture.runtime_compiler),
                patch.object(
                    runner, "_resolved_executable",
                    side_effect=lambda executable: executable,
                ),
                patch.object(runner, "_find_lld_linker", return_value=fixture.linker),
                patch.object(
                    runner, "_controlled_environment",
                    return_value=fixture.environment,
                ),
                patch.object(
                    runner, "_probe_controlled_target",
                    side_effect=[fixture.target, fixture.target],
                ),
                patch.object(
                    runner, "_probe_controlled_system_headers",
                    side_effect=[True, True],
                ) as header_probe,
            ):
                plan = runner._compiler_build_plan()

            self.assertIsNotNone(plan)
            self.assertTrue(plan.controlled)
            self.assertTrue(plan.cache_supported)
            self.assertEqual(plan.target, fixture.target)
            self.assertIn("--no-default-config", plan.driver_flags)
            self.assertEqual(plan.environment, fixture.environment)
            self.assertEqual(header_probe.call_count, 2)

    def test_runtime_headers_unavailable_disable_cache_with_exact_cxx_probe(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self.make_plan(Path(temp_dir) / "fixture")
            with (
                patch.object(runner.sys, "platform", "win32"),
                patch.object(runner, "DIST_C_MAIN", fixture.anchor_source),
                patch.object(runner, "RUNTIME_CPP", fixture.runtime_source),
                patch.object(runner, "find_clang", return_value=fixture.clang),
                patch.object(runner.shutil, "which", return_value=fixture.runtime_compiler),
                patch.object(
                    runner, "_resolved_executable",
                    side_effect=lambda executable: executable,
                ),
                patch.object(runner, "_find_lld_linker", return_value=fixture.linker),
                patch.object(
                    runner, "_controlled_environment",
                    return_value=fixture.environment,
                ),
                patch.object(
                    runner, "_probe_controlled_target",
                    side_effect=[fixture.target, fixture.target],
                ),
                patch.object(
                    runner, "_probe_controlled_system_headers",
                    side_effect=[True, False],
                ) as header_probe,
            ):
                plan = runner._compiler_build_plan()

            self.assertIsNotNone(plan)
            self.assertFalse(plan.controlled)
            self.assertFalse(plan.cache_supported)
            self.assertEqual(plan.driver_flags, ())
            cxx_call = header_probe.call_args_list[1]
            self.assertEqual(cxx_call.args[0], fixture.runtime_compiler)
            self.assertEqual(cxx_call.args[4:6], ("c++", "c++17"))
            self.assertIn("-D_CRT_SECURE_NO_WARNINGS", cxx_call.args[6])

    def test_missing_explicit_linker_preserves_original_uncached_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = self.make_plan(Path(temp_dir) / "fixture")
            with (
                patch.object(runner.sys, "platform", "win32"),
                patch.object(runner, "DIST_C_MAIN", fixture.anchor_source),
                patch.object(runner, "RUNTIME_CPP", fixture.runtime_source),
                patch.object(
                    runner, "find_clang", return_value=fixture.clang,
                ),
                patch.object(
                    runner.shutil, "which",
                    return_value=fixture.runtime_compiler,
                ),
                patch.object(
                    runner, "_resolved_executable",
                    side_effect=lambda executable: executable,
                ),
                patch.object(runner, "_find_lld_linker", return_value=None),
                patch.object(runner, "_probe_controlled_target") as probe,
            ):
                plan = runner._compiler_build_plan()

            self.assertIsNotNone(plan)
            self.assertFalse(plan.controlled)
            self.assertFalse(plan.cache_supported)
            self.assertEqual(plan.linker, "")
            self.assertEqual(plan.linker_pin_flags, ())
            self.assertIsNone(runner._plan_environment(plan))
            probe.assert_not_called()

    def test_build_failure_report_preserves_original_diagnostics(self) -> None:
        failure = subprocess.CalledProcessError(
            23, ["clang", "-c", "main.c"],
            output=b"original stdout\n", stderr=b"original stderr\n",
        )
        captured = io.StringIO()
        with redirect_stderr(captured):
            runner._report_compiler_preparation_failure(failure)

        report = captured.getvalue()
        self.assertIn("command exited 23", report)
        self.assertIn("original stdout", report)
        self.assertIn("original stderr", report)


if __name__ == "__main__":
    unittest.main()
