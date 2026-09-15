#!/usr/bin/env python3
"""Install, locate, and exercise Vorton's pinned validation tools."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "target" / "validation"
DOWNLOADS = ROOT / "target" / "validation-downloads"
TOOLS = ROOT / "target" / "validation-tools"
FIXTURES = Path(__file__).resolve().parent / "fixtures"

RUST_VERSION = "1.98.1"
VERUS_VERSION = "0.2026.09.13.671956e"
PROPTEST_VERSION = "1.11.0"
KANI_VERSION = "0.67.0"
KANI_NIGHTLY = "nightly-2025-11-21"
KANI_UNWIND = 4

VERUS_ASSETS = {
    ("Windows", "x86_64"): (
        f"verus-{VERUS_VERSION}-x86-win.zip",
        538_818_415,
        "ecad53bf8cb9bd2207f33ae65253206bbf30130804fc80d8b086cc4d54714b6b",
    ),
    ("Linux", "x86_64"): (
        f"verus-{VERUS_VERSION}-x86-linux.zip",
        485_525_774,
        "08c85b96e0fbbbdcb1b3a9fa8943dce7598c3e7b343680820f649b4e1efda4b4",
    ),
}


class ValidationError(RuntimeError):
    """A missing tool, mismatched version, or inconclusive result."""


def display_command(arguments: list[str]) -> str:
    return " ".join(f'"{argument}"' if " " in argument else argument for argument in arguments)


def run_command(
    arguments: list[str],
    *,
    cwd: Path = ROOT,
    environment: dict[str, str] | None = None,
    show_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    print(f"$ {display_command(arguments)}", flush=True)
    try:
        result = subprocess.run(
            arguments,
            cwd=cwd,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError as error:
        raise ValidationError(f"cannot execute {arguments[0]}: {error}") from error
    if show_output or result.returncode != 0:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n", flush=True)
    if result.stderr and (show_output or result.returncode != 0):
        print(
            result.stderr,
            end="" if result.stderr.endswith("\n") else "\n",
            file=sys.stderr,
            flush=True,
        )
    return result


def require_success(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode != 0:
        raise ValidationError(f"{label} exited with code {result.returncode}")


def command_output(result: subprocess.CompletedProcess[str]) -> str:
    return f"{result.stdout}\n{result.stderr}"


def project_rust() -> None:
    toolchain = (ROOT / "rust-toolchain.toml").read_text(encoding="utf-8")
    channels = re.findall(r'^channel\s*=\s*"([^"]+)"\s*$', toolchain, re.MULTILINE)
    if channels != [RUST_VERSION]:
        raise ValidationError(
            f"rust-toolchain.toml channels are {channels!r}, expected [{RUST_VERSION!r}]"
        )

    rustc = run_command(["rustc", "--version", "--verbose"])
    require_success(rustc, "rustc version probe")
    release = re.search(r"^release: ([^\s]+)$", rustc.stdout, re.MULTILINE)
    if release is None or release.group(1) != RUST_VERSION:
        actual = release.group(1) if release else "unparseable"
        raise ValidationError(f"rustc release is {actual}, expected {RUST_VERSION}")

    cargo = run_command(["cargo", "--version"])
    require_success(cargo, "cargo version probe")
    if re.search(rf"^cargo {re.escape(RUST_VERSION)}(?:\s|$)", cargo.stdout) is None:
        raise ValidationError(
            f"cargo does not belong to the pinned Rust {RUST_VERSION} toolchain"
        )
    print(f"TOOLCHAIN=project RUST={RUST_VERSION} TARGET={platform.system()}-{platform.machine()}")


def normalized_architecture() -> str:
    architecture = platform.machine().lower()
    if architecture in {"amd64", "x86_64"}:
        return "x86_64"
    return architecture


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_verus_archive(name: str, expected_size: int, expected_digest: str) -> Path:
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    archive = DOWNLOADS / name
    if archive.exists():
        actual_size = archive.stat().st_size
        actual_digest = hash_file(archive)
        if actual_size != expected_size or actual_digest != expected_digest:
            raise ValidationError(
                f"cached Verus archive does not match the pinned asset: {archive} "
                f"(size {actual_size}, sha256 {actual_digest}); remove this file before retrying"
            )
        print(f"VERUS_ARCHIVE={archive} SHA256={actual_digest} CACHE=hit")
        return archive

    partial = archive.with_suffix(archive.suffix + ".part")
    if partial.exists():
        raise ValidationError(
            f"partial Verus download exists: {partial}; remove this file before retrying"
        )

    url = (
        "https://github.com/verus-lang/verus/releases/download/"
        f"release/{VERUS_VERSION}/{name}"
    )
    request = urllib.request.Request(url, headers={"User-Agent": "vorton-validation-toolchain"})
    digest = hashlib.sha256()
    size = 0
    try:
        with urllib.request.urlopen(request) as response, partial.open("wb") as destination:
            while chunk := response.read(1024 * 1024):
                destination.write(chunk)
                digest.update(chunk)
                size += len(chunk)
    except Exception as error:
        raise ValidationError(
            f"Verus download failed; partial data, if any, remains at {partial}: {error}"
        ) from error

    actual_digest = digest.hexdigest()
    if size != expected_size or actual_digest != expected_digest:
        raise ValidationError(
            f"downloaded Verus archive does not match the pinned asset: {partial} "
            f"(size {size}, sha256 {actual_digest})"
        )
    partial.replace(archive)
    print(f"VERUS_ARCHIVE={archive} SHA256={actual_digest} CACHE=miss")
    return archive


def extract_verus(archive: Path, install: Path) -> Path:
    if install.exists():
        raise ValidationError(
            f"incomplete Verus installation exists: {install}; remove this directory before retrying"
        )
    install.mkdir(parents=True)
    root = install.resolve()

    try:
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.infolist():
                mode = member.external_attr >> 16
                if stat.S_ISLNK(mode):
                    raise ValidationError(f"Verus archive contains a symlink: {member.filename}")
                destination = (install / member.filename).resolve()
                if not destination.is_relative_to(root):
                    raise ValidationError(
                        f"Verus archive path escapes the installation root: {member.filename}"
                    )
                if member.is_dir():
                    destination.mkdir(parents=True, exist_ok=True)
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(member) as source, destination.open("wb") as output:
                    shutil.copyfileobj(source, output)
                permissions = mode & 0o777
                if permissions:
                    destination.chmod(permissions)
    except Exception as error:
        raise ValidationError(
            f"Verus extraction failed; incomplete files remain at {install}: {error}"
        ) from error

    return verus_release_executable(install)


def verus_release_executable(install: Path) -> Path:
    executable_name = "verus.exe" if platform.system() == "Windows" else "verus"
    executables = [
        path
        for path in install.rglob(executable_name)
        if path.is_file() and len(path.relative_to(install).parts) == 2
    ]
    if len(executables) != 1:
        raise ValidationError(
            f"Verus archive produced {len(executables)} top-level {executable_name} files "
            f"under {install}"
        )
    return executables[0]


def locate_verus(allow_install: bool) -> Path:
    explicit = os.environ.get("VORTON_VERUS")
    executable_name = "verus.exe" if platform.system() == "Windows" else "verus"
    if explicit:
        candidate = Path(explicit).expanduser()
        if candidate.is_dir():
            candidate /= executable_name
        if not candidate.is_file():
            raise ValidationError(f"VORTON_VERUS does not name a file: {candidate}")
        return candidate.resolve()

    key = (platform.system(), normalized_architecture())
    asset = VERUS_ASSETS.get(key)
    if asset is None:
        raise ValidationError(
            f"Verus self-test supports only x86_64 Windows and Linux, found {key[0]} {key[1]}"
        )
    name, expected_size, expected_digest = asset
    install = TOOLS / "verus" / f"{VERUS_VERSION}-{key[0].lower()}-{key[1]}"
    if install.exists():
        return verus_release_executable(install)
    if not allow_install:
        raise ValidationError(
            "pinned Verus is not installed; pass --install or set VORTON_VERUS explicitly"
        )
    archive = download_verus_archive(name, expected_size, expected_digest)
    return extract_verus(archive, install)


def json_objects(output: str, required_key: str) -> list[dict[str, object]]:
    decoder = json.JSONDecoder()
    objects: list[dict[str, object]] = []
    for index, character in enumerate(output):
        if character != "{":
            continue
        try:
            value, _ = decoder.raw_decode(output[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and required_key in value:
            objects.append(value)
    return objects


def verus_build(executable: Path) -> dict[str, object]:
    version = run_command([str(executable), "--version", "--output-json"])
    require_success(version, "Verus version probe")
    reports = json_objects(command_output(version), "verus")
    if len(reports) != 1:
        raise ValidationError(f"Verus version probe produced {len(reports)} build reports")
    build = reports[0].get("verus")
    if not isinstance(build, dict):
        raise ValidationError("Verus version report has no verus object")
    if build.get("version") != VERUS_VERSION:
        raise ValidationError(
            f"Verus version is {build.get('version')!r}, expected {VERUS_VERSION!r}"
        )
    verus_toolchain = build.get("toolchain")
    toolchain_release = (
        re.match(r"^(\d+\.\d+\.\d+)(?:-|$)", verus_toolchain)
        if isinstance(verus_toolchain, str)
        else None
    )
    if toolchain_release is None or toolchain_release.group(1) != RUST_VERSION:
        raise ValidationError(
            f"Verus toolchain is {verus_toolchain!r}, expected Rust {RUST_VERSION!r}"
        )
    print(
        f"TOOL=Verus VERSION={VERUS_VERSION} RUST={verus_toolchain} "
        f"TARGET={build.get('platform')} EXECUTABLE={executable}"
    )
    return build


def verus_report(output: str) -> dict[str, object]:
    reports = json_objects(output, "verification-results")
    if len(reports) != 1:
        raise ValidationError(f"Verus run produced {len(reports)} verification reports")
    report = reports[0].get("verification-results")
    if not isinstance(report, dict):
        raise ValidationError("Verus output has no verification-results object")
    return report


def require_positive_verus(result: subprocess.CompletedProcess[str], target: Path) -> int:
    require_success(result, f"Verus positive target {target}")
    report = verus_report(command_output(result))
    verified = report.get("verified")
    if (
        report.get("success") is not True
        or report.get("encountered-error") is not False
        or report.get("encountered-vir-error") is not False
        or not isinstance(verified, int)
        or verified <= 0
        or report.get("errors") != 0
    ):
        raise ValidationError(f"Verus positive target did not report a nonzero clean proof: {report}")
    print(f"VERDICT=POSITIVE_OK TOOL=Verus TARGET={target} VERIFIED={verified}")
    return verified


def verus_self_test(executable: Path) -> None:
    positive = FIXTURES / "verus_positive.rs"
    source = positive.read_text(encoding="utf-8")
    forbidden = re.search(
        r"\b(?:assume|admit|axiom)\s*\(|external_body|verifier::external",
        source,
    )
    if forbidden:
        raise ValidationError(
            f"Verus positive fixture contains an unverified escape hatch: {forbidden.group(0)}"
        )

    positive_result = run_command([str(executable), "--output-json", str(positive)])
    require_positive_verus(positive_result, positive)

    negative = FIXTURES / "verus_negative.rs"
    negative_result = run_command([str(executable), "--output-json", str(negative)])
    if negative_result.returncode == 0:
        raise ValidationError("Verus negative target unexpectedly exited successfully")
    output = command_output(negative_result)
    report = verus_report(output)
    if (
        report.get("success") is not False
        or report.get("encountered-vir-error") is not False
        or not isinstance(report.get("errors"), int)
        or report["errors"] <= 0
        or "intentional_verus_counterexample" not in output
        or "postcondition not satisfied" not in output
    ):
        raise ValidationError(
            f"Verus negative target was not the expected proof counterexample: {report}"
        )
    print(
        f"VERDICT=EXPECTED_COUNTEREXAMPLE TOOL=Verus TARGET={negative} "
        f"ERRORS={report['errors']}"
    )


def run_verus(allow_install: bool, files: list[Path]) -> None:
    executable = locate_verus(allow_install)
    verus_build(executable)
    if not files:
        verus_self_test(executable)
        return
    for target in files:
        resolved = target.resolve()
        if not resolved.is_file():
            raise ValidationError(f"Verus target does not exist: {resolved}")
        result = run_command([str(executable), "--output-json", str(resolved)])
        require_positive_verus(result, resolved)


def proptest_version() -> None:
    metadata = run_command(
        ["cargo", "metadata", "--locked", "--format-version", "1"],
        show_output=False,
    )
    require_success(metadata, "Cargo metadata for Proptest")
    try:
        packages = json.loads(metadata.stdout)["packages"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise ValidationError(f"cannot parse Cargo metadata: {error}") from error
    versions = sorted(
        package.get("version")
        for package in packages
        if package.get("name") == "proptest"
    )
    if versions != [PROPTEST_VERSION]:
        raise ValidationError(
            f"resolved Proptest versions are {versions}, expected [{PROPTEST_VERSION!r}]"
        )
    print(f"TOOL=Proptest VERSION={PROPTEST_VERSION} RUST={RUST_VERSION}")


def proptest_command(mode: str, record: Path | None = None) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["CARGO_TARGET_DIR"] = str(TARGET / "proptest-build")
    arguments = [
        "cargo",
        "run",
        "--quiet",
        "--locked",
        "--package",
        "vorton-compiler",
        "--example",
        "validation_proptest",
        "--",
        mode,
    ]
    if record is not None:
        arguments.append(str(record))
    return run_command(arguments, environment=environment)


def require_marker(result: subprocess.CompletedProcess[str], marker: str, label: str) -> None:
    require_success(result, label)
    if marker not in command_output(result):
        raise ValidationError(f"{label} did not emit {marker}")


def run_proptest() -> None:
    proptest_version()
    TARGET.mkdir(parents=True, exist_ok=True)
    record = TARGET / "proptest-replay.txt"

    positive = proptest_command("positive")
    require_marker(positive, "VERDICT=POSITIVE_OK", "Proptest positive self-test")
    generated = re.search(r"GENERATED_CASES=(\d+)", command_output(positive))
    if generated is None or int(generated.group(1)) <= 0:
        raise ValidationError("Proptest positive self-test reported zero generated cases")

    negative = proptest_command("negative", record)
    require_marker(
        negative,
        "VERDICT=EXPECTED_COUNTEREXAMPLE",
        "Proptest negative self-test",
    )
    shrunk = re.search(r"SHRUNK_INPUT=(\d+)", command_output(negative))
    if shrunk is None or not record.is_file():
        raise ValidationError("Proptest negative self-test did not preserve its shrunk input")
    record_match = re.search(
        r"^shrunk_input=(\d+)$", record.read_text(encoding="utf-8"), re.MULTILINE
    )
    if record_match is None or record_match.group(1) != shrunk.group(1):
        raise ValidationError("Proptest replay record does not match the reported shrunk input")

    replay = proptest_command("replay", record)
    require_marker(
        replay,
        f"VERDICT=REPLAYED_COUNTEREXAMPLE TARGET=proptest_replay REPLAY_INPUT={shrunk.group(1)}",
        "Proptest replay self-test",
    )
    print(f"PROPTEST_REPLAY_RECORD={record} SHRUNK_INPUT={shrunk.group(1)}")


def kani_environment() -> tuple[Path, dict[str, str]]:
    environment = os.environ.copy()
    explicit_binary = environment.get("VORTON_KANI")
    explicit_home = environment.get("VORTON_KANI_HOME")
    if bool(explicit_binary) != bool(explicit_home):
        raise ValidationError(
            "VORTON_KANI and VORTON_KANI_HOME must be set together for an explicit Kani install"
        )
    if explicit_binary and explicit_home:
        binary = Path(explicit_binary).expanduser().resolve()
        kani_home = Path(explicit_home).expanduser().resolve()
    else:
        install_root = TOOLS / "kani" / KANI_VERSION
        binary = install_root / "bin" / "kani"
        kani_home = TOOLS / "kani-home"
    environment["KANI_HOME"] = str(kani_home)
    environment["PATH"] = str(binary.parent) + os.pathsep + environment.get("PATH", "")
    return binary, environment


def install_kani(environment: dict[str, str]) -> None:
    install_root = TOOLS / "kani" / KANI_VERSION
    install_root.parent.mkdir(parents=True, exist_ok=True)
    result = run_command(
        [
            "cargo",
            "install",
            "--locked",
            "--version",
            KANI_VERSION,
            "--root",
            str(install_root),
            "kani-verifier",
        ],
        environment=environment,
    )
    require_success(result, "Kani installer build")
    setup = install_root / "bin" / "cargo-kani"
    result = run_command([str(setup), "setup"], environment=environment)
    require_success(result, "Kani setup")


def kani_version(binary: Path, environment: dict[str, str]) -> None:
    if not binary.is_file():
        raise ValidationError(f"Kani executable does not exist: {binary}")
    version = run_command([str(binary), "--version"], environment=environment)
    require_success(version, "Kani version probe")
    expected = f"kani {KANI_VERSION}"
    actual_version = command_output(version).strip()
    if actual_version != expected:
        raise ValidationError(f"Kani version is {actual_version!r}, expected {expected!r}")

    kani_home = Path(environment["KANI_HOME"])
    release_home = kani_home / f"kani-{KANI_VERSION}"
    toolchain_file = release_home / "rust-toolchain-version"
    if not toolchain_file.is_file():
        raise ValidationError(f"Kani setup is incomplete: missing {toolchain_file}")
    nightly = toolchain_file.read_text(encoding="utf-8").strip()
    if re.fullmatch(rf"{re.escape(KANI_NIGHTLY)}(?:-[A-Za-z0-9_.-]+)?", nightly) is None:
        raise ValidationError(f"Kani bundled nightly is {nightly!r}, expected {KANI_NIGHTLY!r}")
    rustc_file = release_home / "rustc-version"
    rustc = rustc_file.read_text(encoding="utf-8").strip() if rustc_file.is_file() else "unknown"
    print(
        f"TOOL=Kani VERSION={KANI_VERSION} BUNDLED_RUST={nightly} "
        f"BUNDLED_RUSTC={rustc} TARGET=Linux-{platform.machine()} EXECUTABLE={binary}"
    )


def run_kani_harness(
    binary: Path,
    environment: dict[str, str],
    harness: str,
) -> subprocess.CompletedProcess[str]:
    return run_command(
        [
            str(binary),
            str(FIXTURES / "kani.rs"),
            "--harness",
            harness,
            "--exact",
            "--unwind",
            str(KANI_UNWIND),
        ],
        environment=environment,
    )


def run_kani(allow_install: bool) -> None:
    if platform.system() != "Linux" or normalized_architecture() != "x86_64":
        raise ValidationError(
            "Kani self-test is an explicit x86_64 Linux/WSL supplement and is not supported here"
        )
    binary, environment = kani_environment()
    if not binary.is_file():
        if os.environ.get("VORTON_KANI"):
            raise ValidationError(f"VORTON_KANI does not name a file: {binary}")
        if not allow_install:
            raise ValidationError(
                "pinned Kani is not installed; pass --install or set VORTON_KANI and VORTON_KANI_HOME"
            )
        install_kani(environment)
    kani_version(binary, environment)

    positive = run_kani_harness(binary, environment, "kani_positive")
    require_success(positive, "Kani positive self-test")
    positive_output = command_output(positive)
    if "VERIFICATION:- SUCCESSFUL" not in positive_output:
        raise ValidationError("Kani positive self-test did not report completed verification")
    if re.search(r"Status: (?:FAILURE|UNDETERMINED)", positive_output):
        raise ValidationError("Kani positive self-test contains a failed or undetermined check")
    print(
        f"VERDICT=POSITIVE_OK TOOL=Kani TARGET=kani_positive INPUT=u8<=2 "
        f"UNWIND={KANI_UNWIND} JOBS=1 DEFAULT_CHECKS=enabled"
    )

    negative = run_kani_harness(binary, environment, "kani_negative")
    if negative.returncode == 0:
        raise ValidationError("Kani negative self-test unexpectedly exited successfully")
    negative_output = command_output(negative)
    if (
        "VERIFICATION:- FAILED" not in negative_output
        or "intentional Kani counterexample" not in negative_output
        or re.search(r"Status: UNDETERMINED", negative_output)
        or re.search(r"unwinding assertion.*Status: FAILURE", negative_output, re.DOTALL)
    ):
        raise ValidationError("Kani negative self-test was not the expected assertion counterexample")
    print(
        f"VERDICT=EXPECTED_COUNTEREXAMPLE TOOL=Kani TARGET=kani_negative INPUT=u8<=2 "
        f"UNWIND={KANI_UNWIND} JOBS=1 DEFAULT_CHECKS=enabled"
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tool", choices=("required", "verus", "proptest", "kani"))
    parser.add_argument(
        "--install",
        action="store_true",
        help="install a missing pinned Verus or Kani release under target/",
    )
    parser.add_argument(
        "--file",
        action="append",
        type=Path,
        default=[],
        help="verify a nonzero-proof Verus file instead of running its fixtures",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.file and arguments.tool != "verus":
        raise ValidationError("--file is supported only by the verus command")

    project_rust()
    if arguments.tool == "required":
        run_verus(arguments.install, [])
        run_proptest()
    elif arguments.tool == "verus":
        run_verus(arguments.install, arguments.file)
    elif arguments.tool == "proptest":
        run_proptest()
    else:
        run_kani(arguments.install)
    print(f"VALIDATION_TOOL_SELF_TEST={arguments.tool} RESULT=completed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as error:
        print(f"INFRASTRUCTURE_ERROR={error}", file=sys.stderr)
        raise SystemExit(1) from error
