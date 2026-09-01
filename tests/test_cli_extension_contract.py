from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
CLI_SOURCE = REPO / "compiler" / "cli.vorton"
STD_FILES = (
    "str.vorton",
    "io.vorton",
    "iterator.vorton",
    "list.vorton",
    "map.vorton",
    "set.vorton",
    "num.vorton",
    "result.vorton",
    "fs.vorton",
    "path.vorton",
    "process.vorton",
)


class CliExtensionContractTests(unittest.TestCase):
    def test_source_uses_exact_suffix_helpers(self) -> None:
        source = CLI_SOURCE.read_text(encoding="utf-8")
        self.assertIn('path.ends_with(".vorton")', source)
        self.assertIn("strip_vorton_source_suffix(path_basename(file_path))", source)
        self.assertIn('vorton_output_path(file_path, ".c")', source)
        self.assertIn('vorton_output_path(file_path, ".o")', source)
        self.assertNotIn('.replace(".vorton",', source)
        self.assertLess(
            source.index("if !has_vorton_source_suffix(file_path)"),
            source.index("let source = read_file(file_path)"),
        )

    def test_native_cli_rejects_wrong_suffix_and_preserves_input(self) -> None:
        compiler_text = os.environ.get("VORTON_CLI_TEST_COMPILER", "")
        if not compiler_text:
            self.skipTest("set VORTON_CLI_TEST_COMPILER to a fixed candidate")
        compiler = Path(compiler_text).resolve()
        self.assertTrue(compiler.is_file(), compiler)

        with tempfile.TemporaryDirectory(prefix="vorton_cli_suffix_") as temp:
            root = Path(temp)
            std = root / "std"
            std.mkdir()
            for name in STD_FILES:
                (std / name).write_text("", encoding="utf-8")

            legacy = "".join(("ri", "ng"))
            wrong_names = (
                f"wrong.{legacy}",
                f"mixed.vorton.{legacy}",
                "wrong.txt",
            )
            for name in wrong_names:
                path = root / name
                path.write_text("fn main() {}\n", encoding="utf-8")
                result = subprocess.run(
                    [str(compiler), "check", str(path)],
                    cwd=root,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    check=False,
                )
                self.assertEqual(result.returncode, 1, name)
                self.assertEqual(result.stdout, "", name)
                diagnostic = result.stderr.replace("\r\n", "\n")
                prefix = "Error: input file must end with '.vorton': "
                self.assertTrue(diagnostic.startswith(prefix), diagnostic)
                self.assertEqual(diagnostic.count("\n"), 1, diagnostic)
                self.assertEqual(Path(diagnostic[len(prefix):].strip()).name, name)

            source = root / "nested.vorton.case.vorton"
            source.write_text("fn main() {}\n", encoding="utf-8")
            before = hashlib.sha256(source.read_bytes()).hexdigest()
            result = subprocess.run(
                [str(compiler), "build", str(source), "--target=c"],
                cwd=root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), before)
            self.assertTrue((root / "nested.vorton.case.c").is_file())
            self.assertTrue((root / "nested.vorton.case.o").is_file())
            self.assertFalse((root / "nested.c.case.c").exists())
            self.assertFalse((root / "nested.c.case.o").exists())


if __name__ == "__main__":
    unittest.main()
