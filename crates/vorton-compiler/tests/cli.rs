//! Runs the `vorton` command-line tool on files in a temporary directory.

use std::fs;
use std::process::Command;

/// `vorton build` writes the executable it is asked for and leaves every
/// other file alone, including a C source of the same name next to it.
#[test]
fn build_keeps_files_next_to_the_output() {
    if vorton_compiler::native::find_c_compiler().is_none() {
        panic!("this test needs clang, gcc or cc, or VORTON_CC");
    }
    let work = std::env::temp_dir().join(format!("vorton-cli-test-{}", std::process::id()));
    fs::create_dir_all(&work).unwrap();
    let program = work.join("hello.vorton");
    let source = work.join("hello.c");
    fs::write(&program, "fn main() { print(\"ok\") }\n").unwrap();
    fs::write(&source, "user-owned C source\n").unwrap();

    let status = Command::new(env!("CARGO_BIN_EXE_vorton"))
        .arg("build")
        .arg(&program)
        .status()
        .unwrap();
    let kept = fs::read_to_string(&source);
    let executable = program.with_extension(std::env::consts::EXE_EXTENSION);
    let output = Command::new(&executable).output();
    let _ = fs::remove_dir_all(&work);

    assert!(status.success());
    assert_eq!(kept.unwrap(), "user-owned C source\n");
    let stdout = String::from_utf8_lossy(&output.unwrap().stdout).replace("\r\n", "\n");
    assert_eq!(stdout, "ok\n");
}
