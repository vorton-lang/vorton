//! The `vorton` command-line tool.

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use vorton_compiler::{
    CompileError, OriginRef, SINGLE_FILE_LIBRARY, compile_to_c, native, single_file_project,
};

const USAGE: &str = "usage:
  vorton run <file.vorton>                  compile and run a program
  vorton build <file.vorton> [-o <output>]  compile a program to an executable
  vorton c <file.vorton>                    print the generated C";

fn main() -> ExitCode {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    match run(&arguments) {
        Ok(code) => code,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(1)
        }
    }
}

fn run(arguments: &[String]) -> Result<ExitCode, String> {
    let Some((command, rest)) = arguments.split_first() else {
        return Err(USAGE.to_owned());
    };
    match (command.as_str(), rest) {
        ("c", [file]) => {
            print!("{}", compile_file(Path::new(file))?);
            Ok(ExitCode::SUCCESS)
        }
        ("build", [file]) => {
            let output = Path::new(file).with_extension(std::env::consts::EXE_EXTENSION);
            build(Path::new(file), &output)?;
            Ok(ExitCode::SUCCESS)
        }
        ("build", [file, flag, output]) if flag == "-o" => {
            build(Path::new(file), Path::new(output))?;
            Ok(ExitCode::SUCCESS)
        }
        ("run", [file]) => {
            let work = std::env::temp_dir().join(format!("vorton-{}", std::process::id()));
            std::fs::create_dir_all(&work)
                .map_err(|error| format!("cannot create {}: {error}", work.display()))?;
            let executable = work
                .join("program")
                .with_extension(std::env::consts::EXE_EXTENSION);
            let result = build(Path::new(file), &executable).and_then(|()| {
                Command::new(&executable)
                    .status()
                    .map_err(|error| format!("cannot run the program: {error}"))
            });
            let _ = std::fs::remove_dir_all(&work);
            let status = result?;
            Ok(ExitCode::from(
                status
                    .code()
                    .and_then(|code| u8::try_from(code).ok())
                    .unwrap_or(1),
            ))
        }
        _ => Err(USAGE.to_owned()),
    }
}

fn compile_file(file: &Path) -> Result<String, String> {
    let source = std::fs::read_to_string(file)
        .map_err(|error| format!("cannot read {}: {error}", file.display()))?;
    compile_to_c(&single_file_project(&source)).map_err(|error| render(file, &source, &error))
}

fn build(file: &Path, output: &Path) -> Result<(), String> {
    let c_source = compile_file(file)?;
    let compiler = native::find_c_compiler()
        .ok_or("no C compiler found; install clang or gcc, or set VORTON_CC")?;
    let c_file: PathBuf = output.with_extension("c");
    std::fs::write(&c_file, c_source)
        .map_err(|error| format!("cannot write {}: {error}", c_file.display()))?;
    let result = native::build_executable(&compiler, &c_file, output);
    let _ = std::fs::remove_file(&c_file);
    result
}

fn render(file: &Path, source: &str, error: &CompileError) -> String {
    let (origin, message) = match error {
        CompileError::Project(diagnostic) => (
            diagnostic.primary.as_ref(),
            format!("{:?}", diagnostic.kind),
        ),
        CompileError::Check(diagnostic) => {
            (diagnostic.primary.as_ref(), diagnostic.message.clone())
        }
    };
    match origin {
        Some(OriginRef { library, span, .. }) if *library == SINGLE_FILE_LIBRARY => {
            let (line, column) = line_column(source, span.start);
            format!("{}:{line}:{column}: error: {message}", file.display())
        }
        Some(_) => format!("core: error: {message}"),
        None => format!("{}: error: {message}", file.display()),
    }
}

fn line_column(source: &str, offset: usize) -> (usize, usize) {
    let before = &source[..offset.min(source.len())];
    let line = before.matches('\n').count() + 1;
    let column = before
        .rfind('\n')
        .map_or(before.len(), |start| before.len() - start - 1)
        + 1;
    (line, column)
}
