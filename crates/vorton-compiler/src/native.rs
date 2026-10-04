//! Building native executables from generated C with the system C compiler.

use std::path::Path;
use std::process::Command;

/// The C compilers tried in order when `VORTON_CC` is not set.
const CANDIDATES: &[&str] = &["clang", "gcc", "cc"];

/// Returns the C compiler named by `VORTON_CC`, or the first of `clang`, `gcc`
/// and `cc` that runs.
pub fn find_c_compiler() -> Option<String> {
    if let Ok(compiler) = std::env::var("VORTON_CC")
        && !compiler.is_empty()
    {
        return Some(compiler);
    }
    CANDIDATES
        .iter()
        .find(|candidate| {
            Command::new(candidate)
                .arg("--version")
                .output()
                .is_ok_and(|output| output.status.success())
        })
        .map(|candidate| (*candidate).to_owned())
}

/// Compiles the C11 file `c_source` into the executable `output`.
///
/// The flags keep binary64 arithmetic exact: no contraction into fused
/// multiply-add and no fast-math rewrites.
pub fn build_executable(compiler: &str, c_source: &Path, output: &Path) -> Result<(), String> {
    build_with(compiler, c_source, output, &[])
}

/// Like [`build_executable`], but the program also reports at exit any heap
/// block it did not release.
pub fn build_leak_checked(compiler: &str, c_source: &Path, output: &Path) -> Result<(), String> {
    build_with(compiler, c_source, output, &["-DVT_CHECK_LEAKS"])
}

fn build_with(
    compiler: &str,
    c_source: &Path,
    output: &Path,
    defines: &[&str],
) -> Result<(), String> {
    let mut command = Command::new(compiler);
    command.args(defines);
    command
        .args([
            "-std=c11",
            "-O2",
            "-ffp-contract=off",
            "-fno-fast-math",
            "-Wno-unused-function",
        ])
        .arg(c_source)
        .arg("-o")
        .arg(output);
    if !cfg!(windows) {
        command.arg("-lm");
    }
    let result = command
        .output()
        .map_err(|error| format!("cannot run the C compiler `{compiler}`: {error}"))?;
    if result.status.success() {
        Ok(())
    } else {
        Err(format!(
            "the C compiler `{compiler}` failed:\n{}",
            String::from_utf8_lossy(&result.stderr)
        ))
    }
}
