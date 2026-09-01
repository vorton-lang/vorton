"""Build the tracked C bootstrap into a fresh benchmark output directory.

This helper mirrors ``compiler/scripts/build_native.ps1`` without writing root
artifacts.  Its JSONL phase trace lets the B-176 harness retain compile/runtime/
link wall-time composition while the enclosing Job Object owns exact totals.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Sequence


LINKER_BINDING_SCHEMA = "vorton.check-benchmark.linker-binding.v1"
LINKER_PROBE_STDOUT = "linker-probe.stdout.txt"
LINKER_PROBE_STDERR = "linker-probe.stderr.txt"


def _write_trace(stream: object, value: dict[str, object]) -> None:
    stream.write(json.dumps(value, sort_keys=True) + "\n")
    stream.flush()


def _run_stage(
    name: str,
    argv: Sequence[str],
    *,
    cwd: Path,
    trace_stream: object,
) -> int:
    start_ns = time.perf_counter_ns()
    completed = subprocess.run(list(argv), cwd=cwd, check=False)
    wall_ns = time.perf_counter_ns() - start_ns
    _write_trace(
        trace_stream,
        {
            "schema": "vorton.check-benchmark.bootstrap-phase.v1",
            "phase": name,
            "argv": list(argv),
            "wall_ns": wall_ns,
            "exit_code": completed.returncode,
        },
    )
    return completed.returncode


def _selected_lld_link(stderr: str) -> Path | None:
    for line in stderr.splitlines():
        match = re.match(r'^\s*("(?:\\.|[^"])*")', line)
        if match is None:
            continue
        try:
            token = json.loads(match.group(1))
        except json.JSONDecodeError:
            continue
        candidate = Path(token)
        if candidate.name.lower() not in {"lld-link", "lld-link.exe"}:
            continue
        if candidate.suffix.lower() != ".exe":
            candidate = Path(str(candidate) + ".exe")
        return candidate.resolve()
    return None


def _verify_linker_binding(
    command: Sequence[str], *, lld_link: Path, cwd: Path, output: Path
) -> dict[str, object]:
    probe = [command[0], "-###", *command[1:]]
    completed = subprocess.run(
        probe,
        cwd=cwd,
        capture_output=True,
        timeout=60,
        check=False,
    )
    stdout_path = output / LINKER_PROBE_STDOUT
    stderr_path = output / LINKER_PROBE_STDERR
    stdout_path.write_bytes(completed.stdout)
    stderr_path.write_bytes(completed.stderr)
    selected = _selected_lld_link(
        completed.stderr.decode("utf-8", errors="replace")
    )
    claimed = lld_link.resolve()
    if completed.returncode != 0 or selected != claimed:
        raise RuntimeError(
            "clang linker binding probe did not select the claimed lld-link: "
            f"claimed={claimed}, selected={selected}, exit={completed.returncode}"
        )
    return {
        "schema": LINKER_BINDING_SCHEMA,
        "probe_argv": probe,
        "cwd": str(cwd.resolve()),
        "claimed_path": str(claimed),
        "selected_path": str(selected),
        "exit_code": completed.returncode,
        "stdout": _file_record(stdout_path),
        "stderr": _file_record(stderr_path),
    }


def _file_record(path: Path) -> dict[str, object]:
    return {
        "path": str(path.resolve()),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "bytes": path.stat().st_size,
    }


def _write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--clang", required=True)
    parser.add_argument("--clangxx", required=True)
    parser.add_argument("--lld-link", required=True)
    parser.add_argument("--cache", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    repo = args.repo.resolve()
    output = args.output_dir.resolve()
    if output.exists():
        if not output.is_dir() or any(output.iterdir()):
            print(f"ERROR: output directory must be fresh and empty: {output}", file=sys.stderr)
            return 2
    else:
        output.mkdir(parents=True)
    args.cache.mkdir(parents=True, exist_ok=True)

    clang = Path(args.clang).resolve()
    clangxx = Path(args.clangxx).resolve()
    lld_link = Path(args.lld_link).resolve()
    for label, tool in (
        ("clang", clang), ("clang++", clangxx), ("lld-link", lld_link)
    ):
        if not tool.is_file():
            print(f"ERROR: required {label} executable is missing: {tool}", file=sys.stderr)
            return 2

    anchor = repo / "compiler" / "dist-c" / "main.c"
    runtime = repo / "vorton_runtime.cpp"
    if not anchor.is_file() or not runtime.is_file():
        print("ERROR: tracked C anchor or runtime is missing", file=sys.stderr)
        return 2

    compiler_object = output / "vorton_compiler_lto.o"
    runtime_object = output / "vorton_runtime_lto.o"
    executable = output / "vorton.exe"
    trace = output / "phase-trace.jsonl"
    commands = [
        (
            "anchor_compile",
            [
                str(clang),
                "-c",
                str(anchor),
                "-o",
                str(compiler_object),
                "-std=c11",
                "-O3",
                "-flto=thin",
            ],
        ),
        (
            "runtime_compile",
            [
                str(clangxx),
                "-c",
                str(runtime),
                "-o",
                str(runtime_object),
                "-std=c++17",
                "-D_CRT_SECURE_NO_WARNINGS",
                "-O3",
                "-flto=thin",
            ],
        ),
        (
            "link",
            [
                str(clang),
                str(compiler_object),
                str(runtime_object),
                "-o",
                str(executable),
                "-lmsvcrt",
                "-Wl,/STACK:536870912",
                "-Wl,/MANIFEST:EMBED",
                "-Wl,/MANIFESTUAC:level='asInvoker'",
                "-flto=thin",
                f"-B{lld_link.parent}",
                "-fuse-ld=lld",
                f"-Wl,/lldltocache:{args.cache.resolve()}",
                (
                    "-Wl,/lldltocachepolicy:cache_size_bytes=1073741824:"
                    "cache_size_files=4096:prune_after=168h"
                ),
            ],
        ),
    ]

    with trace.open("w", encoding="utf-8", newline="\n") as trace_stream:
        for name, command in commands:
            if name == "link":
                try:
                    binding = _verify_linker_binding(
                        command, lld_link=lld_link, cwd=repo, output=output
                    )
                except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
                    print(f"ERROR: {exc}", file=sys.stderr)
                    return 2
                _write_json(output / "linker-binding.json", binding)
            exit_code = _run_stage(name, command, cwd=repo, trace_stream=trace_stream)
            if exit_code != 0:
                return exit_code
    print(f"Built: {executable}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
