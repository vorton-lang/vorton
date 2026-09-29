//! Compiles every program under the repository's `tests/run` directory to a
//! native executable, runs it, and compares the result with its expectation
//! files:
//!
//! - `<name>.expected`: the exact standard output;
//! - `<name>.panic`: the exact standard error of a program that must panic
//!   and exit with code 101;
//! - `<name>.error`: the category and line of the first diagnostic of a program
//!   that must not compile, such as `TypeMismatch 3`.
//!
//! Programs are built with the runtime's leak check, so a program that ends
//! normally also fails if it did not release every string exactly once.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use vorton_compiler::diagnostic::FrontendDiagnosticKind;
use vorton_compiler::{
    CompileError, ProjectDiagnosticKind, compile_to_c, native, single_file_project,
};

#[test]
fn run_programs_match_their_expectations() {
    let compiler = native::find_c_compiler()
        .expect("running these tests needs clang, gcc or cc, or VORTON_CC");
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/run");
    let work = std::env::temp_dir().join(format!("vorton-run-tests-{}", std::process::id()));
    fs::create_dir_all(&work).unwrap();

    let mut programs = fs::read_dir(&root)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "vorton")
        })
        .collect::<Vec<_>>();
    programs.sort();
    assert!(!programs.is_empty(), "no programs under {}", root.display());

    let mut failures = Vec::new();
    for program in &programs {
        if let Err(failure) = run_one(&compiler, &work, program) {
            let name = program.file_name().unwrap().to_string_lossy();
            failures.push(format!("{name}: {failure}"));
        }
    }
    let _ = fs::remove_dir_all(&work);
    assert!(
        failures.is_empty(),
        "{} of {} programs failed:\n{}",
        failures.len(),
        programs.len(),
        failures.join("\n")
    );
}

fn run_one(compiler: &str, work: &Path, program: &Path) -> Result<(), String> {
    let source = fs::read_to_string(program).unwrap();
    let expected_stdout = read_expectation(&program.with_extension("expected"));
    let expected_panic = read_expectation(&program.with_extension("panic"));
    let expected_error = read_expectation(&program.with_extension("error"));
    if let Some(expected) = expected_error {
        return match compile_to_c(&single_file_project(&source)) {
            Ok(_) => Err(format!("compiled, but expected {}", expected.trim())),
            Err(error) => {
                let actual = describe(&source, &error);
                if actual == expected.trim() {
                    Ok(())
                } else {
                    Err(format!(
                        "expected {}, got {actual}: {error:?}",
                        expected.trim()
                    ))
                }
            }
        };
    }
    if expected_stdout.is_none() && expected_panic.is_none() {
        return Err("no .expected, .panic or .error file".to_owned());
    }

    let c_source = compile_to_c(&single_file_project(&source))
        .map_err(|error| format!("does not compile: {error:?}"))?;
    let stem = program.file_stem().unwrap().to_string_lossy();
    let c_file = work.join(format!("{stem}.c"));
    let executable: PathBuf = work
        .join(stem.as_ref())
        .with_extension(std::env::consts::EXE_EXTENSION);
    fs::write(&c_file, c_source).unwrap();
    native::build_leak_checked(compiler, &c_file, &executable)?;

    let output = Command::new(&executable)
        .output()
        .map_err(|error| format!("cannot run: {error}"))?;
    let stdout = normalize(&String::from_utf8_lossy(&output.stdout));
    let stderr = normalize(&String::from_utf8_lossy(&output.stderr));
    if let Some(expected) = &expected_stdout
        && stdout != *expected
    {
        return Err(format!(
            "standard output differs\n--- expected\n{expected}--- actual\n{stdout}"
        ));
    }
    match &expected_panic {
        Some(expected) => {
            if output.status.code() != Some(101) || stderr != *expected {
                return Err(format!(
                    "expected a panic with exit code 101 and\n{expected}got {:?} and\n{stderr}",
                    output.status.code()
                ));
            }
        }
        None if !output.status.success() => {
            return Err(format!("exited with {:?}\n{stderr}", output.status.code()));
        }
        None => {}
    }
    Ok(())
}

fn read_expectation(path: &Path) -> Option<String> {
    fs::read_to_string(path).ok().map(|text| normalize(&text))
}

fn normalize(text: &str) -> String {
    text.replace("\r\n", "\n")
}

/// Names a compile error by its diagnostic category and the line it points at.
fn describe(source: &str, error: &CompileError) -> String {
    let (category, origin) = match error {
        CompileError::Check(diagnostic) => (format!("{:?}", diagnostic.kind), &diagnostic.primary),
        CompileError::Project(diagnostic) => {
            let category = match &diagnostic.kind {
                ProjectDiagnosticKind::Frontend(FrontendDiagnosticKind::Lexical(kind)) => {
                    format!("Lexical({kind:?})")
                }
                ProjectDiagnosticKind::Frontend(FrontendDiagnosticKind::Layout(kind)) => {
                    format!("Layout({kind:?})")
                }
                ProjectDiagnosticKind::Frontend(FrontendDiagnosticKind::UnexpectedToken {
                    ..
                }) => "UnexpectedToken".to_owned(),
                kind => {
                    let debug = format!("{kind:?}");
                    debug[..debug.find([' ', '(', '{']).unwrap_or(debug.len())].to_owned()
                }
            };
            (category, &diagnostic.primary)
        }
    };
    match origin {
        Some(origin) => {
            let line = source[..origin.span.start].matches('\n').count() + 1;
            format!("{category} {line}")
        }
        None => category,
    }
}
