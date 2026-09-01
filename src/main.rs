use std::env;
use std::fs;
use std::process::ExitCode;

use vorton::diagnostic::{format_human, format_llm};
use vorton::source::{SourceFile, SourceId};

const EXIT_SUCCESS: u8 = 0;
const EXIT_SOURCE_ERROR: u8 = 1;
const EXIT_INPUT_ERROR: u8 = 2;

#[derive(Clone, Copy)]
enum ErrorFormat {
    Human,
    Llm,
}

fn main() -> ExitCode {
    match run(env::args().skip(1).collect()) {
        Ok(code) => ExitCode::from(code),
        Err(message) => {
            eprintln!("error: {message}");
            eprintln!("\n{}", usage());
            ExitCode::from(EXIT_INPUT_ERROR)
        }
    }
}

fn run(args: Vec<String>) -> Result<u8, String> {
    if matches!(args.as_slice(), [arg] if matches!(arg.as_str(), "-h" | "--help" | "help")) {
        print!("{}", usage());
        return Ok(EXIT_SUCCESS);
    }

    let mut positional = Vec::new();
    let mut error_format = ErrorFormat::Human;
    let mut index = 0;
    while index < args.len() {
        let argument = &args[index];
        if let Some(value) = argument.strip_prefix("--error-format=") {
            error_format = parse_error_format(value)?;
        } else if argument == "--error-format" {
            index += 1;
            let value = args
                .get(index)
                .ok_or("--error-format requires human or llm")?;
            error_format = parse_error_format(value)?;
        } else if argument.starts_with('-') {
            return Err(format!("unknown option '{argument}'"));
        } else {
            positional.push(argument.clone());
        }
        index += 1;
    }

    if positional.first().map(String::as_str) != Some("parse") {
        return Err("expected the 'parse' command".to_owned());
    }
    if positional.len() != 2 {
        return Err("usage requires exactly one input file".to_owned());
    }

    let path = &positional[1];
    let text =
        fs::read_to_string(path).map_err(|error| format!("cannot read '{path}': {error}"))?;
    let source = SourceFile::new(SourceId(0), path.clone(), text)?;
    let output = vorton::parse_source(source);
    if let Err(diagnostics) = &output.syntax {
        match error_format {
            ErrorFormat::Human => eprint!("{}", format_human(&output.source, diagnostics)),
            ErrorFormat::Llm => println!("{}", format_llm(&output.source, diagnostics)),
        }
        return Ok(EXIT_SOURCE_ERROR);
    }

    println!("OK");
    Ok(EXIT_SUCCESS)
}

fn parse_error_format(value: &str) -> Result<ErrorFormat, String> {
    match value {
        "human" => Ok(ErrorFormat::Human),
        "llm" => Ok(ErrorFormat::Llm),
        _ => Err(format!(
            "unsupported error format '{value}'; expected human or llm"
        )),
    }
}

fn usage() -> &'static str {
    "Vorton compiler\n\nUsage:\n  vorton parse <file> [--error-format=human|llm]\n"
}
