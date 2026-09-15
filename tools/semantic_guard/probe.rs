use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::ExitCode;

use vorton_compiler::{LibraryId, LibrarySources, ProjectSources, check_project, decode_contract};

fn run(source_path: PathBuf, contract_paths: Vec<PathBuf>) -> ExitCode {
    let app = LibraryId(0);
    let core = LibraryId(u32::MAX);
    let source = std::fs::read_to_string(&source_path).expect("read semantic guard source");
    let project = ProjectSources {
        entry: app,
        core,
        libraries: BTreeMap::from([
            (
                app,
                LibrarySources {
                    root: source,
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([("vorton_core".to_owned(), core)]),
                },
            ),
            (
                core,
                LibrarySources {
                    root: include_str!("../../core/root.vorton").to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
        ]),
    };
    let mut documents = Vec::new();
    for path in contract_paths {
        let bytes = std::fs::read(&path).expect("read semantic guard contract");
        let document = match decode_contract(&bytes) {
            Ok(document) => document,
            Err(error) => {
                println!("VERDICT=DECODE_ERROR ERROR={error:?}");
                return ExitCode::from(3);
            }
        };
        documents.push(document);
    }
    let owners = BTreeMap::from([("app".to_owned(), app)]);
    match check_project(&project, &owners, documents) {
        Ok(_) => {
            println!("VERDICT=ACCEPT");
            ExitCode::SUCCESS
        }
        Err(error) => {
            let kind_debug = format!("{:?}", error.kind);
            let kind = kind_debug
                .split(['(', '{'])
                .next()
                .expect("a Debug diagnostic kind has a leading variant");
            println!(
                "VERDICT=REJECT KIND={kind} MESSAGE={:?} PRIMARY={:?}",
                error.message, error.primary
            );
            ExitCode::from(2)
        }
    }
}

fn main() -> ExitCode {
    let mut arguments = std::env::args_os().skip(1);
    let Some(source_path) = arguments.next() else {
        eprintln!("usage: vorton-semantic-guard-probe SOURCE [--contract PATH] [--stack-bytes N]");
        return ExitCode::FAILURE;
    };
    let mut contracts = Vec::new();
    let mut stack_bytes = None;
    while let Some(flag) = arguments.next() {
        match flag.to_str() {
            Some("--contract") => contracts.push(PathBuf::from(
                arguments.next().expect("--contract requires a path"),
            )),
            Some("--stack-bytes") => {
                let value = arguments.next().expect("--stack-bytes requires a size");
                stack_bytes = Some(
                    value
                        .to_str()
                        .expect("stack size is UTF-8")
                        .parse::<usize>()
                        .expect("stack size is an integer"),
                );
            }
            _ => panic!("unknown probe argument {flag:?}"),
        }
    }
    let source_path = PathBuf::from(source_path);
    if let Some(stack_bytes) = stack_bytes {
        return std::thread::Builder::new()
            .stack_size(stack_bytes)
            .spawn(move || run(source_path, contracts))
            .expect("spawn bounded-stack semantic guard thread")
            .join()
            .expect("semantic guard thread must not panic");
    }
    run(source_path, contracts)
}
